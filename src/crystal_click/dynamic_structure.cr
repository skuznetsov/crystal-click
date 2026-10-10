require "set"

module CrystalClick
  # Immutable versioned Dynamic type roster and optional canonical-order
  # statistics. The implicit SharedVariant is spilled data, not NULL.
  class DynamicStructure
    VERSION_V1 = 1_u64
    VERSION_V2 = 2_u64
    VERSION_V3 = 4_u64

    MAX_ORDINARY_TYPES  = 254
    SHARED_VARIANT_NAME = "SharedVariant"

    @types : Array(BinaryDataType)
    @canonical_variant_names : Array(String)
    @shared_index : Int32
    @statistics : StructureStatistics?
    @version : UInt64
    @legacy_max_dynamic_types : UInt64?

    def initialize(
      types : Array(BinaryDataType),
      statistics : StructureStatistics? = nil,
      version : UInt64 = VERSION_V3,
      legacy_max_dynamic_types : UInt64? = nil,
    )
      unless version == VERSION_V1 || version == VERSION_V2 || version == VERSION_V3
        raise ArgumentError.new("Dynamic structure version is outside the MergeTree part-version domain")
      end

      if types.size > MAX_ORDINARY_TYPES
        raise ArgumentError.new("Dynamic supports at most 254 ordinary types")
      end

      if version == VERSION_V1
        # ClickHouse writes this legacy VarUInt slot for V1 compatibility but
        # deliberately ignores it on read. Preserve it as opaque wire identity;
        # newly constructed V1 structures use the actual roster count.
        @legacy_max_dynamic_types = legacy_max_dynamic_types || types.size.to_u64
      else
        if legacy_max_dynamic_types
          raise ArgumentError.new("legacy max_dynamic_types is only valid for Dynamic V1")
        end
        @legacy_max_dynamic_types = nil
      end

      @version = version
      @types = types.dup
      names = [String.new(SHARED_VARIANT_NAME.to_slice)] of String
      seen = Set(String).new
      seen.add(names[0])
      @types.each do |type|
        if type.contains_aggregate_function? &&
           !BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(type)
          raise ArgumentError.new("AggregateFunction alternatives are outside the admitted static Dynamic V3 profile")
        end
        if type.tag == BinaryDataType::TAG_DYNAMIC
          raise ArgumentError.new("Dynamic alternatives are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_VARIANT
          raise ArgumentError.new("Variant-containing alternatives are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
          raise ArgumentError.new("top-level Nothing and Nullable are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
          raise ArgumentError.new("LowCardinality(Nullable) alternatives are not admitted in Dynamic V3")
        end
        name = String.new(type.name.to_slice)
        if seen.includes?(name)
          raise ArgumentError.new("Dynamic V3 alternatives must have unique SQL display names")
        end
        seen.add(name)
        names << name
      end
      @canonical_variant_names = names.sort
      @shared_index = @canonical_variant_names.index(SHARED_VARIANT_NAME).not_nil!

      if value = statistics
        unless value.count_count == @canonical_variant_names.size
          raise ArgumentError.new("Dynamic statistics count does not match canonical variant order")
        end
      end
      @statistics = statistics
    end

    def types : Array(BinaryDataType)
      @types.dup
    end

    def type_count : Int32
      @types.size
    end

    def type_at(index : Int) : BinaryDataType
      @types[index]
    end

    def canonical_variant_names : Array(String)
      @canonical_variant_names.map { |name| String.new(name.to_slice) }
    end

    def canonical_variant_count : Int32
      @canonical_variant_names.size
    end

    # Canonical arm index for one ordinary descriptor. SharedVariant has no
    # ordinary descriptor and is addressed by #shared_index instead.
    def canonical_index_for(type : BinaryDataType) : Int32
      name = type.name
      @canonical_variant_names.index(name) || raise ArgumentError.new("Dynamic type is absent from its canonical roster")
    end

    def shared_index : Int32
      @shared_index
    end

    def statistics : StructureStatistics?
      @statistics
    end

    def version : UInt64
      @version
    end

    def legacy_max_dynamic_types : UInt64?
      @legacy_max_dynamic_types
    end

    def ==(other : DynamicStructure) : Bool
      return false unless @types == other.@types && @canonical_variant_names == other.@canonical_variant_names
      @shared_index == other.@shared_index && @statistics == other.@statistics &&
        @version == other.@version && @legacy_max_dynamic_types == other.@legacy_max_dynamic_types
    end

    def_hash @types, @canonical_variant_names, @shared_index, @statistics, @version, @legacy_max_dynamic_types
  end
end
