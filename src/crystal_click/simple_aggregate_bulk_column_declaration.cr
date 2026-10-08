module CrystalClick
  # Bounded declaration adapter for the generic SimpleAggregateFunction
  # BinaryBulk route. It preserves nominal SAF identity and only admits the
  # two outer shapes supported by the source law; a Nullable storage child
  # remains inside the SAF declaration.
  class SimpleAggregateBulkColumnDeclaration
    getter type : BinaryDataType
    getter simple_aggregate_type : BinarySimpleAggregateType

    @outer_nullable : Bool
    @declaration : String

    # Parse only exact canonical SimpleAggregateFunction spellings. The root
    # may be wrapped once in Nullable, and the SAF storage child may itself be
    # wrapped once in Nullable; the two nullable positions remain distinct.
    def self.parse(
      source : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : BinaryDataType?
      # Enforce the SQL-name and caller byte caps before byte_slice creates a
      # detached child declaration for either nominal wrapper.
      return nil if source.bytesize > BinarySimpleAggregateType::MAX_TYPE_BYTES
      return nil if source.bytesize.to_i64 > limits.max_bytes

      outer_nullable = source.starts_with?("Nullable(") && source.ends_with?(")")
      aggregate_source = if outer_nullable
                           source.byte_slice("Nullable(".bytesize, source.bytesize - "Nullable()".bytesize)
                         else
                           source
                         end
      aggregate_type = BinarySimpleAggregateType.parse(aggregate_source) || return nil

      # The source law rejects Nullable(SAF(... Nullable(T))). Do this before
      # constructing the outer wrapper, whose generic constructor enforces
      # the same rule but raises rather than returning a parse miss.
      if outer_nullable && aggregate_type.storage_type_name.starts_with?("Nullable(")
        return nil
      end

      storage_type_name = aggregate_type.storage_type_name
      inner_nullable = storage_type_name.starts_with?("Nullable(")
      leaf_name = if inner_nullable
                    storage_type_name.byte_slice("Nullable(".bytesize, storage_type_name.bytesize - "Nullable()".bytesize)
                  else
                    storage_type_name
                  end
      leaf = binary_storage_leaf(leaf_name) || return nil
      storage_type = inner_nullable ? BinaryDataType.nullable(leaf) : leaf
      type = BinaryDataType.simple_aggregate(aggregate_type.function, storage_type)
      type = BinaryDataType.nullable(type) if outer_nullable

      # Besides nominal equality, the descriptor budget covers its actual
      # bounded depth/nodes/edges before canonical spelling is materialized.
      declaration = new(type, limits)
      return nil unless declaration.declaration == source
      type
    rescue ex : CorruptPartError | UnsupportedFormatError
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

      if @outer_nullable && aggregate_type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
        raise UnsupportedFormatError.new("outer Nullable(SimpleAggregateFunction(... Nullable(storage))) is not admitted")
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
      @declaration = String.new(canonical.to_slice)
    end

    def outer_nullable? : Bool
      @outer_nullable
    end

    def declaration : String
      String.new(@declaration.to_slice)
    end

    private def self.binary_storage_leaf(source : String) : BinaryDataType?
      if decimal = DecimalType.parse(source)
        return BinaryDataType.decimal(
          decimal.storage_width * 8,
          decimal.precision,
          decimal.scale,
        )
      end

      if temporal = TemporalStorageType.parse(source)
        return case temporal.family
               when TemporalStorageType::Family::Date
                 BinaryDataType.primitive("Date")
               when TemporalStorageType::Family::Date32
                 BinaryDataType.primitive("Date32")
               when TemporalStorageType::Family::Time
                 BinaryDataType.primitive("Time")
               when TemporalStorageType::Family::DateTime
                 BinaryDataType.datetime(temporal.time_zone?.try(&.name))
               when TemporalStorageType::Family::DateTime64
                 BinaryDataType.datetime64(
                   temporal.precision?.not_nil!,
                   temporal.time_zone?.try(&.name),
                 )
               when TemporalStorageType::Family::Time64
                 BinaryDataType.time64(temporal.precision?.not_nil!)
               end
      end

      if width = BinarySimpleAggregateType.fixed_string_width(source)
        return BinaryDataType.fixed_string(width)
      end

      return BinaryDataType.primitive(source) if source == "String" ||
        BinarySimpleAggregateType.storage_width(source) != nil

      nil
    end
  end
end
