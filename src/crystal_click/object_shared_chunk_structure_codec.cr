module CrystalClick
  # Codec for one ADVANCED/ADVANCED_CHUNKED Object shared-data chunk record.
  # Exact-blob methods are convenient standalone envelopes; read_from/write_to
  # compose multiple records under one caller-owned context and budget.
  module ObjectSharedChunkStructureCodec
    TRANSPORT_SUFFIX_BYTES = 48_u64

    def self.encode(
      record : ObjectSharedChunkStructure,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      write_to(record, context)
      context.finish_bytes
    end

    def self.decode(
      bytes : Bytes,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : ObjectSharedChunkStructure
      context = BinaryCodecContext.new(limits, bytes)
      record = read_from(context)
      context.ensure_consumed
      record
    end

    def self.write_to(record : ObjectSharedChunkStructure, context : BinaryCodecContext) : Nil
      unless context.budget.writing?
        raise ArgumentError.new("Object shared chunk encode requires a writing context")
      end

      context.visit_node(1)
      context.write_var_uint(record.row_count)
      path_count = record.path_count.to_u64
      context.preflight_metadata(path_count, label: "Object shared chunk path count")
      context.visit_metadata_nodes(path_count, 1)
      context.write_var_uint(path_count)
      record.path_count.times do |index|
        path = record.path_at(index)
        bytes = path.to_slice
        context.write_var_uint(bytes.size.to_u64)
        context.write_slice(bytes)
      end

      write_pair(context, record.data_marks)
      write_pair(context, record.paths_marks)
      write_pair(context, record.paths_substreams_metadata_marks)
      nil
    end

    def self.read_from(context : BinaryCodecContext) : ObjectSharedChunkStructure
      unless !context.budget.writing?
        raise ArgumentError.new("Object shared chunk decode requires a reading context")
      end

      # The record itself is one logical node at the inherited root depth.
      # Split input performs this visit in its per-record loop before calling
      # read_header; keep the interleaved path symmetric and exactly-once.
      context.visit_node(1)
      row_count, paths = read_header(context)
      data_marks = read_pair(context)
      paths_marks = read_pair(context)
      paths_substreams_metadata_marks = read_pair(context)
      begin
        ObjectSharedChunkStructure.new(
          row_count,
          paths,
          data_marks,
          paths_marks,
          paths_substreams_metadata_marks
        )
      rescue ex : ArgumentError
        context.corrupt!("invalid Object shared chunk structure: #{ex.message}")
      end
    end

    # Reads the source-split SharedData representation: all variable record
    # headers are in StructurePrefix and all fixed coordinate suffixes are in
    # StructureSuffix. The two inputs are never concatenated, so no synthetic
    # interleaved Structure bytes or replacement codec budget are introduced.
    def self.read_split_records(
      prefix : Bytes,
      suffix : Bytes,
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedChunkStructure)
      read_split_records_core(prefix, suffix, budget) do |record, _, _|
        record
      end
    end

    # Reads the same callback-split representation as read_split_records,
    # retaining each header's exact parser-observed interval in the original
    # StructurePrefix callback. No per-record prefix or physical lane is
    # synthesized.
    def self.read_split_record_spans(
      prefix : Bytes,
      suffix : Bytes,
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedChunkStructureReadSpan)
      read_split_records_core(prefix, suffix, budget) do |record, prefix_start, prefix_end|
        ObjectSharedChunkStructureReadSpan.new(record, prefix_start, prefix_end)
      end
    end

    private def self.read_split_records_core(
      prefix : Bytes,
      suffix : Bytes,
      budget : BinaryCodecBudget,
      &block : ObjectSharedChunkStructure, Int32, Int32 -> T
    ) : Array(T) forall T
      unless !budget.writing?
        raise ArgumentError.new("split Object shared structure decode requires a read-direction budget")
      end
      unless suffix.size > 0 && suffix.size % TRANSPORT_SUFFIX_BYTES.to_i == 0
        raise CorruptPartError.new("Object shared StructureSuffix is not a whole record roster")
      end
      record_count = suffix.size.to_u64 // TRANSPORT_SUFFIX_BYTES
      if record_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared split structure record count exceeds Int32")
      end
      budget.ensure_wire_bytes(suffix.size.to_u64)
      budget.charge_wire_bytes(suffix.size.to_u64)
      budget.ensure_future_nodes(record_count)
      budget.ensure_future_elements(record_count)

      context = BinaryCodecContext.new(budget.limits, prefix, false, budget, false)
      records = Array(T).new(record_count.to_i)
      record_count.to_i.times do |index|
        context.visit_node(1)
        prefix_start = context.input_offset
        row_count, paths = read_header(context, (record_count - index.to_u64) * TRANSPORT_SUFFIX_BYTES)
        prefix_end = context.input_offset
        suffix_offset = index * TRANSPORT_SUFFIX_BYTES.to_i
        record_end = suffix_offset + TRANSPORT_SUFFIX_BYTES.to_i
        if record_end > suffix.size
          raise CorruptPartError.new("Object shared StructureSuffix is truncated")
        end
        data_marks = read_pair(suffix, suffix_offset)
        paths_marks = read_pair(suffix, suffix_offset + 16)
        metadata_marks = read_pair(suffix, suffix_offset + 32)
        record = begin
          ObjectSharedChunkStructure.new(row_count, paths, data_marks, paths_marks, metadata_marks)
        rescue ex : ArgumentError
          raise CorruptPartError.new("invalid split Object shared chunk structure: #{ex.message}")
        end
        records << block.call(record, prefix_start, prefix_end)
      end
      context.ensure_consumed
      records
    end

    private def self.read_header(
      context : BinaryCodecContext,
      split_suffix_remaining : UInt64? = nil,
    ) : Tuple(UInt64, Array(String))
      row_count = context.read_var_uint
      raw_path_count = context.read_var_uint
      path_count = context.preflight_metadata(
        raw_path_count,
        maximum_count: Int32::MAX.to_u64,
        label: "Object shared chunk declared path count"
      )

      # Keep the original early lower-bound guard: every path needs at least
      # its one-byte length prefix, and its six-UInt64 coordinate suffix must
      # be present before path arrays or per-path nodes are retained.
      if suffix_remaining = split_suffix_remaining
        context.ensure_remaining_input_bytes(raw_path_count)
        if suffix_remaining < TRANSPORT_SUFFIX_BYTES
          context.corrupt!("Object shared StructureSuffix is truncated")
        end
      else
        minimum_remaining = raw_path_count + TRANSPORT_SUFFIX_BYTES
        context.ensure_remaining_input_bytes(minimum_remaining)
      end
      context.visit_metadata_nodes(raw_path_count, 1)

      path_slices = Array(Bytes).new(path_count)
      previous_path : Bytes? = nil
      path_count.times do
        path_size = context.read_var_uint
        path = context.read_slice(path_size)
        if previous = previous_path
          unless compare_path_bytes(previous, path) < 0
            context.corrupt!("Object shared chunk paths are not byte-sorted and unique")
          end
        end
        path_slices << path
        previous_path = path
      end
      if split_suffix_remaining.nil?
        context.ensure_remaining_input_bytes(TRANSPORT_SUFFIX_BYTES)
      end
      paths = path_slices.map { |path| String.new(path) }
      {row_count, paths}
    end

    private def self.read_pair(context : BinaryCodecContext) : Tuple(UInt64, UInt64)
      {read_u64_le(context), read_u64_le(context)}
    end

    private def self.read_pair(bytes : Bytes, offset : Int) : Tuple(UInt64, UInt64)
      if offset < 0 || offset > bytes.size - 16
        raise CorruptPartError.new("Object shared split coordinate suffix is truncated")
      end
      {read_u64_le(bytes, offset), read_u64_le(bytes, offset + 8)}
    end

    private def self.compare_path_bytes(left : Bytes, right : Bytes) : Int32
      common_size = Math.min(left.size, right.size)
      common_size.times do |index|
        return -1 if left[index] < right[index]
        return 1 if left[index] > right[index]
      end
      left.size <=> right.size
    end

    private def self.write_pair(context : BinaryCodecContext, pair : Tuple(UInt64, UInt64)) : Nil
      write_u64_le(context, pair[0])
      write_u64_le(context, pair[1])
    end

    private def self.read_u64_le(context : BinaryCodecContext) : UInt64
      value = 0_u64
      8.times do |index|
        value |= context.read_byte.to_u64 << (index * 8)
      end
      value
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("Object shared split UInt64 coordinate is truncated")
      end
      value = 0_u64
      8.times do |index|
        value |= bytes[offset + index].to_u64 << (index * 8)
      end
      value
    end

    private def self.write_u64_le(context : BinaryCodecContext, value : UInt64) : Nil
      8.times do |index|
        context.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
    end
  end
end
