module CrystalClick
  # Exact complete-blob codec for the admitted MergeTree Dynamic V3
  # descriptor roster and optional statistics.
  module DynamicStructureCodec
    def self.encode(
      structure : DynamicStructure,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      write_to(structure, context)
      context.finish_bytes
    end

    def self.decode(
      bytes : Bytes,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : DynamicStructure
      context = BinaryCodecContext.new(limits, bytes)
      structure = read_from(context)
      context.ensure_consumed
      structure
    end

    # Internal shared-budget entry point. Descriptor trees begin at depth one;
    # this structure envelope does not add a recursive descriptor level.
    def self.write_to(structure : DynamicStructure, context : BinaryCodecContext) : Nil
      context.visit_node(1)
      write_u64_le(context, 4_u64)

      type_count = structure.type_count
      context.preflight_metadata(
        type_count.to_u64,
        maximum_count: DynamicStructure::MAX_ORDINARY_TYPES.to_u64,
        label: "Dynamic type count"
      )
      context.write_var_uint(type_count.to_u64)
      type_count.times do |index|
        BinaryDataTypeCodec.write_to(structure.type_at(index), context, 1)
      end

      if statistics = structure.statistics
        context.write_byte(1_u8)
        StructureStatisticsCodec.write(statistics, context, structure.canonical_variant_count)
      else
        context.write_byte(0_u8)
      end
      nil
    end

    # Internal shared-budget entry point for a paired structure operation.
    def self.read_from(context : BinaryCodecContext) : DynamicStructure
      context.visit_node(1)
      version = read_u64_le(context)
      case version
      when 4_u64
        # Current MergeTree Dynamic V3 uses binary descriptors.
      when 1_u64, 2_u64
        context.unsupported!("older Dynamic part structure version #{version} is not admitted")
      when 3_u64
        context.corrupt!("Dynamic FLATTENED version is Native-only, not a MergeTree part version")
      else
        context.corrupt!("Dynamic structure version #{version} is outside the known part-version domain")
      end

      raw_type_count = context.read_var_uint
      type_count = context.preflight_metadata(
        raw_type_count,
        1_u64,
        DynamicStructure::MAX_ORDINARY_TYPES.to_u64,
        "Dynamic type declared metadata count"
      )
      types = Array(BinaryDataType).new(type_count)
      type_count.times do
        types << BinaryDataTypeCodec.read_from(context, 1)
      end

      types.each do |type|
        if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
          context.unsupported!("top-level Nothing and Nullable are not admitted in Dynamic V3")
        end
      end

      profile = begin
        DynamicStructure.new(types)
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic V3 alternative roster: #{ex.message}")
      end

      statistics = case context.read_byte
                   when 0_u8
                     nil
                   when 1_u8
                     StructureStatisticsCodec.read(context, profile.canonical_variant_count)
                   else
                     context.corrupt!("Dynamic statistics flag must be zero or one")
                   end

      begin
        DynamicStructure.new(types, statistics)
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic V3 statistics: #{ex.message}")
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
  end
end
