module CrystalClick
  # Exact complete-blob codec for the admitted MergeTree Object V1/V2/V3
  # structure metadata. It does not parse prefixes independently of statistics.
  module ObjectStructureCodec
    def self.encode(
      structure : ObjectStructure,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      write_to(structure, context)
      context.finish_bytes
    end

    def self.decode(
      bytes : Bytes,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : ObjectStructure
      context = BinaryCodecContext.new(limits, bytes)
      structure = read_from(context)
      context.ensure_consumed
      structure
    end

    # Internal shared-budget entry point for a paired Object + Dynamic batch.
    def self.write_to(structure : ObjectStructure, context : BinaryCodecContext) : Nil
      context.visit_node(1)
      write_u64_le(context, structure.version)

      if structure.version == 0_u64
        legacy = structure.legacy_max_dynamic_paths || raise ArgumentError.new("Object V1 requires its legacy maximum-path field")
        context.write_var_uint(legacy)
      end

      path_count = structure.dynamic_path_count
      context.preflight_metadata(
        path_count.to_u64,
        maximum_count: Int32::MAX.to_u64,
        label: "Object dynamic path count"
      )
      context.visit_metadata_nodes(path_count.to_u64, 1)

      path_order = Array(Int32).new(path_count)
      path_count.times { |index| path_order << index }
      path_order.sort! { |left, right| compare_paths(structure, left, right) }

      context.write_var_uint(path_count.to_u64)
      path_order.each do |index|
        path_size = structure.dynamic_path_byte_size(index)
        context.write_var_uint(path_size.to_u64)
        path_size.times do |byte_index|
          context.write_byte(structure.dynamic_path_byte_at(index, byte_index))
        end
      end

      if structure.version == 4_u64
        context.write_var_uint(structure.shared_data_version)
        if structure.shared_data_version != 0_u64
          context.write_var_uint(structure.bucket_count)
        end
        if statistics = structure.statistics
          context.write_byte(1_u8)
          StructureStatisticsCodec.write(statistics, context, path_count, path_order)
        else
          context.write_byte(0_u8)
        end
      else
        statistics = structure.statistics || raise ArgumentError.new("Object V1/V2 requires complete legacy statistics")
        StructureStatisticsCodec.write(statistics, context, path_count, path_order)
      end
      nil
    end

    # Internal shared-budget entry point for a paired Object + Dynamic batch.
    def self.read_from(context : BinaryCodecContext) : ObjectStructure
      context.visit_node(1)
      version = read_u64_le(context)
      case version
      when 0_u64, 2_u64, 4_u64
        # These are the only admitted MergeTree Object structure versions.
      when 1_u64, 3_u64
        context.corrupt!("Object structure version #{version} is Native-only, not a MergeTree part version")
      else
        context.corrupt!("Object structure version #{version} is outside the known part-version domain")
      end

      legacy_max_dynamic_paths = version == 0_u64 ? context.read_var_uint : nil
      raw_path_count = context.read_var_uint
      path_count = context.preflight_metadata(
        raw_path_count,
        1_u64,
        Int32::MAX.to_u64,
        "Object dynamic path declared metadata count"
      )
      context.visit_metadata_nodes(raw_path_count, 1)
      paths = Array(String).new(path_count)
      path_count.times do
        name_size = context.read_var_uint
        paths << String.new(context.read_slice(name_size))
      end

      shared_data_version = 0_u64
      bucket_count = 1_u64
      if version == 4_u64
        shared_data_version = context.read_var_uint
        if shared_data_version > 3_u64
          context.corrupt!("Object shared-data version is outside the admitted domain 0 through 3")
        end
        if shared_data_version != 0_u64
          bucket_count = context.read_var_uint
          if bucket_count < 1_u64 || bucket_count > 256_u64
            context.corrupt!("Object shared-data bucket count must be between 1 and 256")
          end
        end
      end

      statistics = if version == 4_u64
                     case context.read_byte
                     when 0_u8
                       nil
                     when 1_u8
                       StructureStatisticsCodec.read(context, path_count)
                     else
                       context.corrupt!("Object statistics flag must be zero or one")
                     end
                   else
                     StructureStatisticsCodec.read(context, path_count)
                   end

      begin
        ObjectStructure.new(
          paths,
          version: version,
          shared_data_version: shared_data_version,
          bucket_count: bucket_count,
          legacy_max_dynamic_paths: legacy_max_dynamic_paths,
          statistics: statistics
        )
      rescue ex : ArgumentError
        context.corrupt!("invalid Object structure metadata: #{ex.message}")
      end
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

    private def self.compare_paths(structure : ObjectStructure, left : Int32, right : Int32) : Int32
      common_size = Math.min(
        structure.dynamic_path_byte_size(left),
        structure.dynamic_path_byte_size(right)
      )
      common_size.times do |index|
        left_byte = structure.dynamic_path_byte_at(left, index)
        right_byte = structure.dynamic_path_byte_at(right, index)
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      structure.dynamic_path_byte_size(left) <=> structure.dynamic_path_byte_size(right)
    end
  end
end
