module CrystalClick
  # The source factory first strips LowCardinality recursively, then applies
  # the outer Nullable combinator. This profile retains the nominal argument
  # elsewhere and supplies only the dispatched value type used inside a
  # single-value state.
  module BinaryAggregateMinMaxArgumentPolicy
    enum StateKind
      Fixed
      String
      Generic
    end

    def self.require!(argument_type : BinaryDataType) : Profile
      if argument_type.contains_dynamic?
        raise ArgumentError.new("AggregateFunction min/max does not admit Dynamic argument types")
      end
      if argument_type.contains_variant?
        raise ArgumentError.new("AggregateFunction min/max does not admit Variant argument types")
      end
      if argument_type.contains_qbit?
        raise ArgumentError.new("QBit is outside the admitted AggregateFunction min/max argument profile")
      end
      if argument_type.contains_json?
        raise ArgumentError.new("JSON is outside the admitted AggregateFunction min/max argument profile")
      end
      if argument_type.contains_aggregate_function?
        raise ArgumentError.new("AggregateFunction arguments are outside the admitted min/max profile")
      end

      dispatched = strip_low_cardinality(argument_type)
      nullable = dispatched.tag == BinaryDataType::TAG_NULLABLE
      input_type = nullable ? dispatched.child_at(0) : dispatched

      # Nothing may be comparable in ClickHouse's factory, but the current
      # ordinary value codec has no non-NULL Nothing body grammar. Keep it
      # policy-unqualified until that serializer contract is explicitly added.
      unless comparable_static_tree?(input_type)
        raise ArgumentError.new("AggregateFunction min/max argument is outside the admitted comparable static profile")
      end

      kind = case input_type.tag
             when BinaryDataType::TAG_STRING
               StateKind::String
             when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                  BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                  BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                  BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                  BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                  BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                  BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                  BinaryDataType::TAG_BOOL,
                  BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
                  BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
                  BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATETIME,
                  BinaryDataType::TAG_DATETIME_ZONE,
                  BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE
               StateKind::Fixed
             else
               StateKind::Generic
             end

      if kind == StateKind::Fixed && input_type.fixed_width.nil?
        raise ArgumentError.new("AggregateFunction min/max fixed argument has no source-compatible carrier width")
      end

      Profile.new(input_type, kind, nullable)
    end

    def self.strip_low_cardinality(type : BinaryDataType) : BinaryDataType
      # Process iteratively: this policy runs during descriptor construction,
      # before the operation budget has had a chance to bound recursive work.
      normalized = Hash(UInt64, BinaryDataType).new
      stack = [] of Tuple(BinaryDataType, Bool)
      stack << {type, false}

      until stack.empty?
        current, expanded = stack.pop
        identity = current.object_id
        next if normalized.has_key?(identity)

        unless expanded
          stack << {current, true}
          current.child_count.times do |index|
            child = current.child_at(index)
            stack << {child, false} unless normalized.has_key?(child.object_id)
          end
          next
        end

        children = Array(BinaryDataType).new(current.child_count) do |index|
          normalized[current.child_at(index).object_id]
        end
        normalized[identity] = case current.tag
                               when BinaryDataType::TAG_LOW_CARDINALITY
                                 children[0]
                               when BinaryDataType::TAG_ARRAY
                                 BinaryDataType.array(children[0])
                               when BinaryDataType::TAG_NESTED
                                 BinaryDataType.nested(children[0])
                               when BinaryDataType::TAG_UNNAMED_TUPLE
                                 BinaryDataType.tuple(children)
                               when BinaryDataType::TAG_NAMED_TUPLE
                                 BinaryDataType.tuple(children, current.field_names)
                               when BinaryDataType::TAG_MAP
                                 BinaryDataType.map(children[0], children[1])
                               when BinaryDataType::TAG_NULLABLE
                                 BinaryDataType.nullable(children[0])
                               else
                                 current
                               end
      end

      normalized[type.object_id]
    end

    private def self.comparable_static_tree?(root : BinaryDataType) : Bool
      stack = [root] of BinaryDataType
      until stack.empty?
        current = stack.pop
        case current.tag
        when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
          stack << current.child_at(0)
        when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
          current.child_count.times do |index|
            stack << current.child_at(index)
          end
        when BinaryDataType::TAG_MAP
          stack << current.child_at(0)
          stack << current.child_at(1)
        when BinaryDataType::TAG_NULLABLE
          stack << current.child_at(0)
        when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
             BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
             BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
             BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
             BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
             BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
             BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
             BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
             BinaryDataType::TAG_STRING, BinaryDataType::TAG_FIXED_STRING,
             BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
             BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
             BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
             BinaryDataType::TAG_TIME, BinaryDataType::TAG_TIME64,
             BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16,
             BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
             BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
             BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4, BinaryDataType::TAG_IPV6,
             BinaryDataType::TAG_INTERVAL
          nil
        else
          return false
        end
      end
      true
    end
  end
end
