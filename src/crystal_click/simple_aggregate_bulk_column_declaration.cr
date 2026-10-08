module CrystalClick
  # Bounded declaration adapter for the generic SimpleAggregateFunction
  # BinaryBulk route. It preserves the complete nominal descriptor and exact
  # recursively parsed storage tree while enforcing the route's bounded
  # static physical child profile.
  class SimpleAggregateBulkColumnDeclaration
    getter type : BinaryDataType
    getter simple_aggregate_type : BinarySimpleAggregateType

    @outer_nullable : Bool
    @declaration : String

    # Parse one exact canonical recursive DataType tree. In particular, do
    # not render an SAF child and feed it through a narrower leaf parser: the
    # descriptor retains the original immutable child tree and parameters.
    def self.parse(
      source : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > limits.max_bytes

      type = BinaryRecursiveDataTypeNameReader.parse_canonical(source, limits) || return nil

      # Besides nominal equality, the descriptor budget covers its actual
      # bounded depth/nodes/edges before canonical spelling is materialized.
      declaration = new(type, limits)
      return nil unless declaration.declaration == source
      type
    rescue ex : ArgumentError | BoundsError | CorruptPartError | UnsupportedFormatError
      nil
    end

    def initialize(
      @type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      aggregate_type = case @type.tag
                       when BinaryDataType::TAG_SIMPLE_AGGREGATE
                         @outer_nullable = false
                         @type
                       when BinaryDataType::TAG_NULLABLE
                         child = @type.child_at(0)
                         unless child.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE
                           raise UnsupportedFormatError.new("SimpleAggregate bulk declaration requires a root SAF or outer Nullable(SAF)")
                         end
                         @outer_nullable = true
                         child
                       else
                         raise UnsupportedFormatError.new("SimpleAggregate bulk declaration requires a root SAF or outer Nullable(SAF)")
                       end

      @simple_aggregate_type = aggregate_type.simple_aggregate_type ||
                               raise UnsupportedFormatError.new("SimpleAggregate descriptor metadata is missing")

      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(@type, budget)
      canonical = BinaryTypeNameBudget.materialize(@type, budget, bounds)
      canonical_bytes = canonical.bytesize.to_u64
      budget.ensure_wire_bytes(canonical_bytes)
      budget.charge_wire_bytes(canonical_bytes)

      expected = @outer_nullable ? "Nullable(#{@simple_aggregate_type.type_name})" : @simple_aggregate_type.type_name
      unless canonical == expected
        raise UnsupportedFormatError.new("SimpleAggregate nominal child differs from its canonical storage declaration")
      end
      validate_static_storage!(aggregate_type.child_at(0))
      @declaration = String.new(canonical.to_slice)
    end

    def outer_nullable? : Bool
      @outer_nullable
    end

    def declaration : String
      String.new(@declaration.to_slice)
    end

    # This low-level declaration boundary is intentionally broader than
    # WidePart's public/table admission: it keeps the established bare and
    # outer-Nullable scalar forms usable, while admitting the bounded
    # recursive Array/Tuple/Map grammar over established scalar codecs. Paired
    # native cases are finite witnesses, not an exhaustive topology matrix.
    private def validate_static_storage!(storage : BinaryDataType) : Nil
      if @outer_nullable
        unless static_scalar?(storage)
          raise UnsupportedFormatError.new("outer Nullable SimpleAggregate bulk storage is limited to paired scalar leaves")
        end
        return nil
      end

      if storage.tag == BinaryDataType::TAG_NULLABLE
        unless static_scalar?(storage.child_at(0))
          raise UnsupportedFormatError.new("SimpleAggregate Nullable storage requires one paired scalar child")
        end
        return nil
      end

      return nil if static_scalar?(storage)
      return nil if static_collection?(storage)

      raise UnsupportedFormatError.new("SimpleAggregate storage is outside the admitted static physical profile")
    end

    private def static_collection?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_ARRAY
        static_collection_child?(type.child_at(0))
      when BinaryDataType::TAG_MAP
        # The current Map profile binds a scalar key lane and composes the
        # value subtree through the generic static child codecs.
        static_scalar?(type.child_at(0)) && static_collection_child?(type.child_at(1))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        return false if type.child_count == 0
        type.child_count.times do |index|
          return false unless static_collection_child?(type.child_at(index))
        end
        true
      else
        false
      end
    end

    private def static_collection_child?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_MAP,
           BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        static_collection?(type)
      else
        # Nullable, LC, Nested, JSON, Dynamic, Variant, QBit and other
        # unqualified contexts deliberately stop recursive admission here.
        static_scalar?(type)
      end
    end

    private def static_scalar?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_STRING,
           BinaryDataType::TAG_FIXED_STRING, BinaryDataType::TAG_DECIMAL32,
           BinaryDataType::TAG_DECIMAL64, BinaryDataType::TAG_DECIMAL128,
           BinaryDataType::TAG_DECIMAL256, BinaryDataType::TAG_DATE,
           BinaryDataType::TAG_DATE32, BinaryDataType::TAG_TIME,
           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
           BinaryDataType::TAG_TIME64
        true
      else
        false
      end
    end
  end
end
