module CrystalClick
  module LZ4
    def self.decode(input : Bytes, expected_size : Int) : Bytes
      raise CorruptPartError.new("negative LZ4 output size") if expected_size < 0
      output = Bytes.new(expected_size)
      input_index = 0
      output_index = 0

      while input_index < input.size
        token = input[input_index]
        input_index += 1

        literal_length, input_index = length(input, input_index, token >> 4)
        ensure_input(input_index, literal_length, input.size)
        ensure_output(output_index, literal_length, output.size)
        input[literal_start = input_index, literal_length].copy_to(output[output_index, literal_length])
        input_index += literal_length
        output_index += literal_length

        break if input_index == input.size

        ensure_input(input_index, 2, input.size)
        distance = input[input_index].to_i | (input[input_index + 1].to_i << 8)
        input_index += 2
        raise CorruptPartError.new("invalid LZ4 match distance") if distance == 0 || distance > output_index

        match_length, input_index = length(input, input_index, token & 0x0f)
        match_length += 4
        ensure_output(output_index, match_length, output.size)
        match_start = output_index - distance
        match_length.times do |offset|
          output[output_index + offset] = output[match_start + offset]
        end
        output_index += match_length
      end

      raise CorruptPartError.new("LZ4 output size mismatch") unless output_index == expected_size
      output
    end

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
