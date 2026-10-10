module CrystalClick
  # Exact complete-blob codec for admitted MergeTree Dynamic V1, V2, and V3
  # descriptor rosters and their version-specific statistics framing.
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

    # Prefix-only frames store the version and ordinary roster without any
    # statistics bytes; the caller owns their exact enclosing slice.
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

    # Writes complete metadata and returns the relative position before its
    # statistics suffix without finishing or copying the encoded blob.
    def self.write_with_statistics_offset(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
    ) : Int32
      parse_start = context.output_size
      write_prefix_without_statistics(structure, context, structure_depth, type_depth)
      statistics_offset = context.output_size - parse_start
      if structure.version == DynamicStructure::VERSION_V3
        if statistics = structure.statistics
          context.write_byte(1_u8)
          StructureStatisticsCodec.write(statistics, context, structure.canonical_variant_count)
        else
          context.write_byte(0_u8)
        end
      else
        statistics = structure.statistics ||
                     raise UnsupportedFormatError.new("complete Dynamic V1/V2 metadata requires statistics")
        StructureStatisticsCodec.write(statistics, context, structure.canonical_variant_count)
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
      context.visit_node(structure_depth)
      write_u64_le(context, structure.version)

      if structure.version == DynamicStructure::VERSION_V1
        legacy_max_dynamic_types = structure.legacy_max_dynamic_types ||
                                   raise UnsupportedFormatError.new("Dynamic V1 structure is missing its legacy maximum")
        context.write_var_uint(legacy_max_dynamic_types)
      end

      type_count = structure.type_count
      context.preflight_metadata(
        type_count.to_u64,
        maximum_count: DynamicStructure::MAX_ORDINARY_TYPES.to_u64,
        label: "Dynamic type count"
      )
      context.write_var_uint(type_count.to_u64)
      type_count.times do |index|
        type = structure.type_at(index)
        if structure.version == DynamicStructure::VERSION_V3
          BinaryDataTypeCodec.write_to(type, context, type_depth)
        else
          bounds = BinaryTypeNameBudget.measure(type, context.budget, type_depth)
          name = BinaryTypeNameBudget.materialize(type, context.budget, bounds)
          unless name.valid_encoding?
            raise UnsupportedFormatError.new("Dynamic V1/V2 SQL type name is not valid UTF-8")
          end
          parsed = BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, context.budget, type_depth)
          unless parsed == type
            raise UnsupportedFormatError.new("Dynamic V1/V2 SQL type name does not preserve descriptor identity")
          end
          write_string_binary(name, context)
        end
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

    # Reads complete metadata while exposing the relative start of its
    # statistics suffix for paired mark checks.
    def self.read_with_statistics_offset(
      context : BinaryCodecContext,
      structure_depth : Int = 1,
      type_depth : Int = 1,
      preflight_type_names : Bool = false,
    ) : Tuple(DynamicStructure, Int32)
      parse_start = context.input_offset
      profile, types = read_prefix_without_statistics_internal(context, structure_depth, type_depth, preflight_type_names)
      statistics_offset = (context.input_offset - parse_start).to_i32
      statistics = if profile.version == DynamicStructure::VERSION_V3
                     case context.read_byte
                     when 0_u8
                       nil
                     when 1_u8
                       StructureStatisticsCodec.read(context, profile.canonical_variant_count)
                     else
                       context.corrupt!("Dynamic statistics flag must be zero or one")
                     end
                   else
                     StructureStatisticsCodec.read(context, profile.canonical_variant_count)
                   end

      begin
        structure = DynamicStructure.new(
          types,
          statistics,
          profile.version,
          profile.legacy_max_dynamic_types,
        )
        {structure, statistics_offset}
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic statistics: #{ex.message}")
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
      legacy_max_dynamic_types = nil.as(UInt64?)
      case version
      when DynamicStructure::VERSION_V3
        # Current MergeTree Dynamic V3 uses binary descriptors.
      when DynamicStructure::VERSION_V1
        # ClickHouse skips this historical compatibility field and uses only
        # the actual roster count that follows it.
        legacy_max_dynamic_types = context.read_var_uint
      when DynamicStructure::VERSION_V2
        # V2 has a textual roster but no historical maximum field.
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
        if version == DynamicStructure::VERSION_V3
          types << BinaryDataTypeCodec.read_from(context, type_depth)
        else
          name_size = context.read_var_uint
          name = String.new(context.read_slice(name_size))
          unless name.valid_encoding?
            context.corrupt!("Dynamic V1/V2 SQL type name is not valid UTF-8")
          end
          type = BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, context.budget, type_depth)
          unless type
            context.corrupt!("Dynamic V1/V2 SQL type name is not a supported canonical descriptor")
          end
          types << type
        end
      end

      types.each do |type|
        if type.tag == BinaryDataType::TAG_DYNAMIC
          message = if version == DynamicStructure::VERSION_V3
                      "Dynamic alternatives are not admitted in Dynamic V3"
                    else
                      "Dynamic alternatives are not admitted in a Dynamic ordinary roster"
                    end
          context.unsupported!(message)
        end
        if type.tag == BinaryDataType::TAG_VARIANT
          message = if version == DynamicStructure::VERSION_V3
                      "Variant-containing alternatives are not admitted in Dynamic V3"
                    else
                      "Variant-containing alternatives are not admitted in a Dynamic ordinary roster"
                    end
          context.unsupported!(message)
        end
        if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
          message = if version == DynamicStructure::VERSION_V3
                      "top-level Nothing and Nullable are not admitted in Dynamic V3"
                    else
                      "top-level Nothing and Nullable are not admitted in a Dynamic ordinary roster"
                    end
          context.unsupported!(message)
        end
        if type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
          message = if version == DynamicStructure::VERSION_V3
                      "LowCardinality(Nullable) alternatives are not admitted in Dynamic V3"
                    else
                      "LowCardinality(Nullable) alternatives are not admitted in a Dynamic ordinary roster"
                    end
          context.unsupported!(message)
        end
      end

      name_work_bytes = 0_u64
      # Text-name versions must always budget the canonical roster names that
      # DynamicStructure materializes. Binary V3 keeps its existing opt-in
      # preflight contract for callers that do not cross an untrusted name
      # boundary.
      if preflight_type_names || version != DynamicStructure::VERSION_V3
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
        DynamicStructure.new(types, nil, version, legacy_max_dynamic_types)
      rescue ex : ArgumentError
        context.corrupt!("invalid Dynamic alternative roster: #{ex.message}")
      end
      {profile, types}
    end

    private def self.write_string_binary(value : String, context : BinaryCodecContext) : Nil
      context.write_var_uint(value.bytesize.to_u64)
      context.write_slice(value.to_slice)
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
