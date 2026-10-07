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

    # Compact Object Dynamic V3 stores only the descriptor prefix in the
    # substream; unlike the complete metadata blob, it omits the statistics
    # flag as well as any statistics payload.
    def self.encode_prefix_without_statistics(
      structure : DynamicStructure,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      write_prefix_without_statistics(structure, context)
      context.finish_bytes
    end

    def self.decode_prefix_without_statistics(
      bytes : Bytes,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : DynamicStructure
      context = BinaryCodecContext.new(limits, bytes)
      structure = read_prefix_without_statistics(context)
      context.ensure_consumed
      structure
    end

    # Internal shared-budget entry point. Descriptor trees begin at depth one;
    # this structure envelope does not add a recursive descriptor level.
    def self.write_to(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
    ) : Nil
      write_with_statistics_offset(structure, context, structure_depth, type_depth)
      nil
    end

    # Writes the complete metadata and returns the relative position before its
    # statistics flag without finishing or copying the encoded blob.
    def self.write_with_statistics_offset(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
    ) : Int32
      parse_start = context.output_size
      write_prefix_without_statistics(structure, context, structure_depth, type_depth)
      statistics_offset = context.output_size - parse_start
      if statistics = structure.statistics
        context.write_byte(1_u8)
        StructureStatisticsCodec.write(statistics, context, structure.canonical_variant_count)
      else
        context.write_byte(0_u8)
      end
      statistics_offset
    end

    # Writes only the version and ordinary descriptor roster. The caller owns
    # framing/finish and may continue writing the surrounding Compact stream.
    def self.write_prefix_without_statistics(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
    ) : Nil
      reject_wrapped_json_actual_types!(structure, context)

      context.visit_node(structure_depth)
      write_u64_le(context, 4_u64)

      type_count = structure.type_count
      context.preflight_metadata(
        type_count.to_u64,
        maximum_count: DynamicStructure::MAX_ORDINARY_TYPES.to_u64,
        label: "Dynamic type count"
      )
      context.write_var_uint(type_count.to_u64)
      type_count.times do |index|
        BinaryDataTypeCodec.write_to(structure.type_at(index), context, type_depth)
      end
      nil
    end

    # Internal shared-budget entry point for a paired structure operation.
    def self.read_from(
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
      preflight_type_names : Bool = false,
    ) : DynamicStructure
      read_with_statistics_offset(context, structure_depth, type_depth, preflight_type_names)[0]
    end

    # Reads the complete metadata while exposing the relative start of the
    # statistics suffix flag for paired mark checks.
    def self.read_with_statistics_offset(
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
      preflight_type_names : Bool = false,
    ) : Tuple(DynamicStructure, Int32)
      parse_start = context.input_offset
      profile, types = read_prefix_without_statistics_internal(context, structure_depth, type_depth, preflight_type_names)
      statistics_offset = (context.input_offset - parse_start).to_i32
      statistics = case context.read_byte
                   when 0_u8
                     nil
                   when 1_u8
                     StructureStatisticsCodec.read(context, profile.canonical_variant_count)
                   else
                     context.corrupt!("Dynamic statistics flag must be zero or one")
                   end

      begin
        structure = DynamicStructure.new(types, statistics)
        {structure, statistics_offset}
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic V3 statistics: #{ex.message}")
      end
    end

    # Reads only the descriptor roster and leaves the cursor at the first byte
    # following that prefix. This is the paired Compact-profile path; callers
    # decide the exact bounded slice and final-consumption rule.
    def self.read_prefix_without_statistics(
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
      preflight_type_names : Bool = false,
    ) : DynamicStructure
      read_prefix_without_statistics_internal(context, structure_depth, type_depth, preflight_type_names)[0]
    end

    private def self.read_prefix_without_statistics_internal(
      context : BinaryCodecContext,
      structure_depth : Int,
      type_depth : Int,
      preflight_type_names : Bool,
    ) : Tuple(DynamicStructure, Array(BinaryDataType))
      context.visit_node(structure_depth)
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
        types << BinaryDataTypeCodec.read_from(context, type_depth)
      end

      types.each do |type|
        if type.contains_json? && type.tag != BinaryDataType::TAG_JSON
          context.unsupported!("JSON-containing wrappers are not admitted as Dynamic actual types")
        end
        if type.tag == BinaryDataType::TAG_DYNAMIC
          context.unsupported!("Dynamic alternatives are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_VARIANT
          context.unsupported!("Variant-containing alternatives are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
          context.unsupported!("top-level Nothing and Nullable are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
          context.unsupported!("LowCardinality(Nullable) alternatives are not admitted in Dynamic V3")
        end
      end

      name_work_bytes = 0_u64
      if preflight_type_names
        # DynamicStructure canonicalizes names twice while checking the roster
        # and retaining its statistics-bearing form. Measure both operations,
        # including each detached retained-name copy, before either constructor
        # materializes a recursive SQL display name.
        2.times do
          types.each do |type|
            bounds = BinaryTypeNameBudget.measure(type, context.budget, type_depth)
            work = bounds[1]
            if bounds[0] > UInt64::MAX - work
              context.corrupt!("Dynamic display-name work size overflows UInt64")
            end
            work += bounds[0]
            if work > UInt64::MAX - name_work_bytes
              context.corrupt!("Dynamic display-name work size overflows UInt64")
            end
            name_work_bytes += work
          end
        end
        context.budget.ensure_wire_bytes(name_work_bytes)
        context.budget.charge_wire_bytes(name_work_bytes)
      end

      profile = begin
        DynamicStructure.new(types)
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic V3 alternative roster: #{ex.message}")
      end
      {profile, types}
    end

    private def self.read_u64_le(context : BinaryCodecContext) : UInt64
      value = 0_u64
      8.times do |index|
        value |= context.read_byte.to_u64 << (index * 8)
      end
      value
    end

    private def self.reject_wrapped_json_actual_types!(
      structure : DynamicStructure,
      context : BinaryCodecContext,
    ) : Nil
      structure.type_count.times do |index|
        type = structure.type_at(index)
        if type.contains_json? && type.tag != BinaryDataType::TAG_JSON
          context.unsupported!("JSON-containing wrappers are not admitted as Dynamic actual types")
        end
      end
      nil
    end

    private def self.write_u64_le(context : BinaryCodecContext, value : UInt64) : Nil
      8.times do |index|
        context.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
    end
  end
end
