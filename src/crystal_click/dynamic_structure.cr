require "set"

module CrystalClick
  # Immutable Dynamic V3 type roster and optional canonical-order statistics.
  # The implicit SharedVariant is a spilled value alternative, not NULL.
  class DynamicStructure
    MAX_ORDINARY_TYPES  = 254
    SHARED_VARIANT_NAME = "SharedVariant"

    @types : Array(BinaryDataType)
    @canonical_variant_names : Array(String)
    @shared_index : Int32
    @statistics : StructureStatistics?

    def initialize(types : Array(BinaryDataType), statistics : StructureStatistics? = nil)
      if types.size > MAX_ORDINARY_TYPES
        raise ArgumentError.new("Dynamic V3 supports at most 254 ordinary types")
      end

      @types = types.dup
      names = [String.new(SHARED_VARIANT_NAME.to_slice)] of String
      seen = Set(String).new
      seen.add(names[0])
      @types.each do |type|
        if type.contains_variant?
          raise ArgumentError.new("Variant-containing alternatives are not admitted in Dynamic V3")
        end
        if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
          raise ArgumentError.new("top-level Nothing and Nullable are not admitted in Dynamic V3")
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

    def shared_index : Int32
      @shared_index
    end

    def statistics : StructureStatistics?
      @statistics
    end

    def ==(other : DynamicStructure) : Bool
      return false unless @types == other.@types && @canonical_variant_names == other.@canonical_variant_names
      @shared_index == other.@shared_index && @statistics == other.@statistics
    end

    def_hash @types, @canonical_variant_names, @shared_index, @statistics
  end
end
