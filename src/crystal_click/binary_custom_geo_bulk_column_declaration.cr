module CrystalClick
  # Static part admission for nominal Geo wrappers. Recognizing a Custom
  # descriptor in the neutral codec does not authorize runtime-owned layouts.
  class BinaryCustomGeoBulkColumnDeclaration
    getter type : BinaryDataType
    getter declaration : String

    def initialize(
      @type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(@type, budget)
      canonical = BinaryTypeNameBudget.materialize(@type, budget, bounds)
      unless @type.contains_custom_geo?
        raise UnsupportedFormatError.new("Custom Geo bulk declaration requires a nominal Geo descendant")
      end
      if @type.contains_low_cardinality? || @type.contains_dynamic? ||
         @type.contains_json? || @type.contains_aggregate_function? || @type.contains_qbit?
        raise UnsupportedFormatError.new("Custom Geo bulk declaration is outside the plain static owner profile")
      end
      validate_static_node!(@type)
      BinaryBulkTypePlan.new(@type, BinaryBulkProfile.single_stream, nil, limits, true).role_count
      budget.charge_wire_bytes(canonical.bytesize.to_u64)
      @declaration = String.new(canonical.to_slice)
    end

    def self.parse(
      source : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > limits.max_bytes
      parsed = BinaryRecursiveDataTypeNameReader.parse_canonical(source, limits) || return nil
      declaration = new(parsed, limits)
      return nil unless declaration.declaration == source
      parsed
    rescue ex : ArgumentError | BoundsError | CorruptPartError | UnsupportedFormatError
      nil
    end

    private def validate_static_node!(type : BinaryDataType) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM,
           BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times { |index| validate_static_node!(type.child_at(index)) }
      when BinaryDataType::TAG_MAP
        key = type.child_at(0)
        unless !key.contains_custom_geo? &&
               (key.tag == BinaryDataType::TAG_STRING || !key.fixed_width.nil?)
          raise UnsupportedFormatError.new("Custom Geo bulk Map requires an ordinary scalar key")
        end
        validate_static_node!(key)
        validate_static_node!(type.child_at(1))
      when BinaryDataType::TAG_STRING, BinaryDataType::TAG_BOOL, BinaryDataType::TAG_NOTHING
        nil
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("Custom Geo bulk declaration contains an unqualified owner")
        end
      end
    end
  end
end
