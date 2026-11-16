module CrystalClick
  module LZ4
    PADDING_SIZE = 7

    private struct ExactOutput
    end

    private struct PaddedOutput
    end

    def self.decode(input : Bytes, expected_size : Int) : Bytes
      raise CorruptPartError.new("negative LZ4 output size") if expected_size < 0
      output = Bytes.new(expected_size)
      decode_into(input, output, expected_size)
    end

    def self.decode_into(input : Bytes, output : Bytes, expected_size : Int) : Bytes
      raise CorruptPartError.new("negative LZ4 output size") if expected_size < 0
      raise CorruptPartError.new("LZ4 destination is too small") if output.size < expected_size
      raise BoundsError.new("LZ4 destination must be writable") if output.read_only?
      decode_into_impl(ExactOutput, input, output, expected_size)
    end

    # The output must not alias input. The supplied output slice needs seven
    # writable padding bytes beyond the logical result; those bytes may change.
    def self.decode_into_padded(input : Bytes, output : Bytes, expected_size : Int) : Bytes
      raise CorruptPartError.new("negative LZ4 output size") if expected_size < 0
      if output.size < expected_size || output.size - expected_size < PADDING_SIZE
        raise CorruptPartError.new("LZ4 padded destination is too small")
      end
      raise BoundsError.new("LZ4 destination must be writable") if output.read_only?
      decode_into_impl(PaddedOutput, input, output, expected_size)
    end

    private def self.decode_into_impl(mode : T.class, input : Bytes, output : Bytes, expected_size : Int) : Bytes forall T
      {% unless T == PaddedOutput %}
        output = output[0, expected_size]
      {% end %}
      input_index = 0
      output_index = 0

      {% if flag?(:read_rows_profile) %}
        ReadRowsProfile.current_worker?.try &.add_lz4_call
        lz4_started = Time.instant
      {% end %}
      while input_index < input.size
        token = input[input_index]
        input_index += 1

        literal_length, input_index = length(input, input_index, token >> 4)
        ensure_input(input_index, literal_length, input.size)
        ensure_output(output_index, literal_length, expected_size)
        {% if T == PaddedOutput %}
          copy_literals_padded(input, input_index, output, output_index, literal_length)
        {% else %}
          copy_literals(input, input_index, output, output_index, literal_length)
        {% end %}
        input_index += literal_length
        output_index += literal_length

        break if input_index == input.size

        ensure_input(input_index, 2, input.size)
        distance = input[input_index].to_i | (input[input_index + 1].to_i << 8)
        input_index += 2
        raise CorruptPartError.new("invalid LZ4 match distance") if distance == 0 || distance > output_index

        match_length, input_index = length(input, input_index, token & 0x0f)
        match_length += 4
        ensure_output(output_index, match_length, expected_size)
        {% if T == PaddedOutput %}
          copy_match_padded(output, output_index, distance, match_length)
        {% else %}
          copy_match_exact(output, output_index, distance, match_length)
        {% end %}
        output_index += match_length
      end
      {% if flag?(:read_rows_profile) %}
        lz4_finished = Time.instant
        ReadRowsProfile.current_worker?.try &.add_lz4(ReadRowsProfile.elapsed_ns_between(lz4_started, lz4_finished))
      {% end %}

      raise CorruptPartError.new("LZ4 output size mismatch") unless output_index == expected_size
      {% if T == PaddedOutput %}
        output[0, expected_size]
      {% else %}
        output
      {% end %}
    end

    @[AlwaysInline]
    private def self.copy_literals(input : Bytes, input_index : Int32, output : Bytes, output_index : Int32, length : Int32) : Nil
      return if length == 0

      source = input.to_unsafe + input_index
      destination = output.to_unsafe + output_index
      case length
      when 1
        source.copy_to(destination, 1)
      when 2
        source.copy_to(destination, 2)
      when 3
        source.copy_to(destination, 2)
        (source + 2).copy_to(destination + 2, 1)
      when 4
        source.copy_to(destination, 4)
      else
        source.copy_to(destination, length)
      end
      nil
    end

    @[AlwaysInline]
    private def self.copy_literals_padded(input : Bytes, input_index : Int32, output : Bytes, output_index : Int32, length : Int32) : Nil
      return if length == 0

      if length < 8 && input.size - input_index >= 8
        # The full load stays inside the compressed byte range. Bytes beyond
        # this literal run are speculative and will be replaced by later output.
        (input.to_unsafe + input_index).copy_to(output.to_unsafe + output_index, 8)
      else
        copy_literals(input, input_index, output, output_index, length)
      end
      nil
    end

    @[AlwaysInline]
    private def self.copy_match_padded(output : Bytes, output_index : Int32, distance : Int32, match_length : Int32) : Nil
      if distance >= 8 && match_length <= 8
        output_pointer = output.to_unsafe
        match_source = output_pointer + output_index - distance
        match_destination = output_pointer + output_index
        # The eight-byte source is initialized and disjoint when distance >= 8.
        # Short matches can overstore only into the caller's seven-byte pad.
        match_source.copy_to(match_destination, 8)
      else
        copy_match_exact(output, output_index, distance, match_length)
      end
      nil
    end

    @[AlwaysInline]
    private def self.copy_match_exact(output : Bytes, output_index : Int32, distance : Int32, match_length : Int32) : Nil
      output_pointer = output.to_unsafe
      match_start = output_index - distance
      match_source = output_pointer + match_start
      match_destination = output_pointer + output_index

      if distance >= match_length
        if match_length <= 7
          # Both four-byte copies stay within this non-overlapping match.
          match_source.copy_to(match_destination, 4)
          tail_offset = match_length - 4
          (match_source + tail_offset).copy_to(match_destination + tail_offset, 4)
        else
          match_source.copy_to(match_destination, match_length)
        end
      else
        # Seed one period, then grow from the initialized prefix. Each copy is disjoint.
        match_source.copy_to(match_destination, distance)
        copied_length = distance
        while copied_length < match_length
          remaining_length = match_length - copied_length
          copy_length = copied_length < remaining_length ? copied_length : remaining_length
          match_destination.copy_to(match_destination + copied_length, copy_length)
          copied_length += copy_length
        end
      end
      nil
    end

    @[AlwaysInline]
    private def self.length(input : Bytes, index : Int, nibble : UInt8) : {Int32, Int32}
      value = nibble.to_i
      return {value, index} unless value == 15

      total = 15
      current = index
      loop do
        ensure_input(current, 1, input.size)
        extension = input[current].to_i
        current += 1
        total += extension
        break unless extension == 255
      end
      {total, current}
    end

    private def self.ensure_input(index : Int, length : Int, size : Int)
      raise CorruptPartError.new("truncated LZ4 input") if index < 0 || length < 0 || index > size - length
    end

    private def self.ensure_output(index : Int, length : Int, size : Int)
      raise CorruptPartError.new("LZ4 output exceeds declared size") if index < 0 || length < 0 || index > size - length
    end
  end
end
