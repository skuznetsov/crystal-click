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

      context.visit_node(1)
      row_count = context.read_var_uint
      raw_path_count = context.read_var_uint
      path_count = context.preflight_metadata(
        raw_path_count,
        maximum_count: Int32::MAX.to_u64,
        label: "Object shared chunk declared path count"
      )

      # Every path needs at least its one-byte length prefix, followed by the
      # complete fixed six-UInt64 suffix. Check the combined lower bound before
      # retaining the count-derived path array or visiting per-path metadata
      # nodes.
      minimum_remaining = raw_path_count + TRANSPORT_SUFFIX_BYTES
      context.ensure_remaining_input_bytes(minimum_remaining)
      context.visit_metadata_nodes(raw_path_count, 1)

      # Keep borrowed byte slices until all path extents and the entire fixed
      # suffix have been proven. In particular, a truncated suffix must not
      # cause variable path Strings to be retained first.
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

      context.ensure_remaining_input_bytes(TRANSPORT_SUFFIX_BYTES)
      data_marks = read_pair(context)
      paths_marks = read_pair(context)
      paths_substreams_metadata_marks = read_pair(context)
      paths = path_slices.map { |path| String.new(path) }
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

    private def self.read_pair(context : BinaryCodecContext) : Tuple(UInt64, UInt64)
      {read_u64_le(context), read_u64_le(context)}
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

    private def self.write_u64_le(context : BinaryCodecContext, value : UInt64) : Nil
      8.times do |index|
        context.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
    end
  end
end
