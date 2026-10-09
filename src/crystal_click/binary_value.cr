module CrystalClick
  # Immutable owned value for the W117 scalar/container grammar. Numeric leaves
  # retain their exact-width little-endian bytes; Float values never pass
  # through host floating-point conversion.
  class BinaryValue
    getter type : BinaryDataType

    @payload : Bytes?
    @elements : Array(BinaryValue)
    @null : Bool
    @variant_index : UInt8?
    @qbit_value : QBitValue?
    @json_row : BinaryJsonRow?

    private def initialize(
      @type : BinaryDataType,
      payload : Bytes? = nil,
      elements : Array(BinaryValue) = [] of BinaryValue,
      @null : Bool = false,
      @variant_index : UInt8? = nil,
      @qbit_value : QBitValue? = nil,
      @json_row : BinaryJsonRow? = nil,
    )
      @payload = payload.try { |bytes| Bytes.new(bytes.size) { |index| bytes[index] } }
      @elements = elements.dup
    end

    # Construct raw bytes for a fixed-width numeric/float leaf or FixedString.
    # String, Bool, Nothing, and recursive types have separate constructors.
    def self.fixed(type : BinaryDataType, bytes : Bytes) : BinaryValue
      width = type.fixed_width || raise ArgumentError.new("type does not have a fixed-width binary payload")
      allowed = case type.tag
                when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                     BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                     BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                     BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                     BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                     BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                     BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                     BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_FIXED_STRING,
                     BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
                     BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
                     BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
                     BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16,
                     BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
                     BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
                     BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4,
                     BinaryDataType::TAG_IPV6, BinaryDataType::TAG_TIME,
                     BinaryDataType::TAG_TIME64, BinaryDataType::TAG_INTERVAL
                  true
                else
                  false
                end
      unless allowed
        raise ArgumentError.new("fixed binary value requires a fixed-width numeric or FixedString type")
      end
      unless bytes.size == width
        raise ArgumentError.new("fixed binary payload width does not match its type")
      end
      new(type, bytes)
    end

    # Retain one immutable QBitValue owner instead of copying its potentially
    # large raw row into the generic scalar payload buffer.
    def self.qbit(value : QBitValue) : BinaryValue
      qbit(BinaryDataType.qbit(value.type), value)
    end

    def self.qbit(type : BinaryDataType, value : QBitValue) : BinaryValue
      unless type.tag == BinaryDataType::TAG_QBIT && type.qbit_type == value.type
        raise ArgumentError.new("QBit value type does not match its nominal descriptor")
      end
      new(type, nil, [] of BinaryValue, false, nil, value)
    end

    # JSON is one nominal scalar with a separately-owned flattened structured
    # row. It is not represented as an ObjectDocument or generic child array.
    def self.json(type : BinaryDataType, row : BinaryJsonRow) : BinaryValue
      unless type.tag == BinaryDataType::TAG_JSON && row.type == type
        raise ArgumentError.new("JSON row does not match its nominal descriptor")
      end
      new(type, nil, [] of BinaryValue, false, nil, nil, row)
    end

    def self.string(value : String) : BinaryValue
      new(BinaryDataType.primitive("String"), value.to_slice)
    end

    def self.bool(value : Bool) : BinaryValue
      new(BinaryDataType.primitive("Bool"), Bytes[BoolValueCodec.encode(value)])
    end

    def self.int64(value : Int64) : BinaryValue
      bits = value.unsafe_as(UInt64)
      new(BinaryDataType.primitive("Int64"), little_endian(bits, 8))
    end

    def self.interval(type : BinaryDataType, count : Int64) : BinaryValue
      unless type.tag == BinaryDataType::TAG_INTERVAL
        raise ArgumentError.new("Interval value requires an Interval type")
      end
      new(type, little_endian(count.unsafe_as(UInt64), 8))
    end

    def self.uint64(value : UInt64) : BinaryValue
      new(BinaryDataType.primitive("UInt64"), little_endian(value, 8))
    end

    # Count is nominally distinct from UInt64 despite using the same owned
    # little-endian carrier in memory.
    def self.aggregate_count_state(type : BinaryDataType, count : UInt64) : BinaryValue
      unless type.tag == BinaryDataType::TAG_AGGREGATE_COUNT && type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) state requires its nominal type")
      end
      new(type, little_endian(count, 8))
    end

    # Non-Count aggregate states are opaque canonical byte sequences. The
    # family-specific plan validates their state and presence grammar, while
    # this value owner copies bytes so callers cannot mutate owned states.
    def self.aggregate_function_state(type : BinaryDataType, canonical_bytes : Bytes) : BinaryValue
      descriptor = type.aggregate_function_type || raise ArgumentError.new("AggregateFunction state requires its nominal type")
      if descriptor.function_name == "count" || type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) state requires the Count compatibility carrier")
      end
      BinaryAggregateFunctionStateCodec.validate_owned_state_bytes(type, canonical_bytes)
      new(type, canonical_bytes)
    end

    # Internal codec factory for one non-Count state read. StateCodec consumes
    # and validates the state under the caller's context/depth exactly once;
    # using `new` here copies those validated bytes without reopening them under
    # a fresh default budget.
    def self.aggregate_function_state_from_context(
      type : BinaryDataType,
      context : BinaryCodecContext,
      depth : Int,
    ) : BinaryValue
      descriptor = type.aggregate_function_type || raise ArgumentError.new("AggregateFunction state requires its nominal type")
      if descriptor.function_name == "count" || type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) state requires the Count compatibility carrier")
      end
      bytes = BinaryAggregateFunctionStateCodec.read(type, context, depth)
      new(type, bytes)
    end

    def self.float32_bits(bits : UInt32) : BinaryValue
      new(BinaryDataType.primitive("Float32"), little_endian(bits.to_u64, 4))
    end

    def self.float64_bits(bits : UInt64) : BinaryValue
      new(BinaryDataType.primitive("Float64"), little_endian(bits, 8))
    end

    def self.null(type : BinaryDataType = BinaryDataType.primitive("Nothing")) : BinaryValue
      unless type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_NULLABLE
        raise ArgumentError.new("NULL value requires Nothing or Nullable type")
      end
      new(type, nil, [] of BinaryValue, true)
    end

    # Dynamic retains its nominal type descriptor while carrying either NULL
    # (no selected value) or one value of the selected runtime type. A
    # Nothing NULL child is the same sentinel and is normalized to no child;
    # NULLs selected through Nullable, Variant, or nested Dynamic stay typed.
    def self.dynamic(type : BinaryDataType, child : BinaryValue? = nil) : BinaryValue
      unless type.tag == BinaryDataType::TAG_DYNAMIC
        raise ArgumentError.new("Dynamic value requires Dynamic type")
      end
      if child && child.type.contains_aggregate_function? &&
         !BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(child.type)
        raise ArgumentError.new("AggregateFunction is outside the admitted static Dynamic actual profile")
      end
      if child && child.type.contains_qbit? && !BinaryDynamicQBitAdmission.admitted_actual_type?(child.type)
        raise ArgumentError.new("QBit is not admitted as a Dynamic actual type")
      end
      if child && child.type.tag == BinaryDataType::TAG_NOTHING
        unless child.is_null?
          raise ArgumentError.new("Dynamic Nothing child must be NULL")
        end
        child = nil
      end
      if selected = child
        new(type, nil, [selected] of BinaryValue)
      else
        new(type, nil, [] of BinaryValue, true)
      end
    end

    # Variant NULL is a separate UInt8 discriminator value (255), not an
    # ordinary arm and not a child value.
    def self.variant_null(type : BinaryDataType) : BinaryValue
      unless type.tag == BinaryDataType::TAG_VARIANT
        raise ArgumentError.new("Variant NULL value requires Variant type")
      end
      new(type, nil, [] of BinaryValue, true)
    end

    def self.variant(type : BinaryDataType, index : Int, child : BinaryValue) : BinaryValue
      unless type.tag == BinaryDataType::TAG_VARIANT
        raise ArgumentError.new("Variant value requires Variant type")
      end
      if index < 0 || index >= type.child_count || index >= 255
        raise ArgumentError.new("Variant discriminator is outside its declared arm roster")
      end
      unless child.type == type.child_at(index)
        raise ArgumentError.new("Variant child type does not match its selected arm")
      end
      new(type, nil, [child] of BinaryValue, false, index.to_u8)
    end

    def self.array(type : BinaryDataType, elements : Array(BinaryValue)) : BinaryValue
      unless type.tag == BinaryDataType::TAG_ARRAY
        raise ArgumentError.new("array value requires Array type")
      end
      validate_children(type.child_at(0), elements)
      new(type, nil, elements)
    end

    # Nested retains its nominal root descriptor while each stored item is a
    # record of the one implicit named Tuple child. This keeps Array(Tuple)
    # construction/access from serving as a nominal substitute.
    def self.nested(type : BinaryDataType, elements : Array(BinaryValue)) : BinaryValue
      tuple_type = BinaryNestedType.tuple_for(type)
      validate_children(tuple_type, elements)
      new(type, nil, elements)
    end

    # A NULL Nullable has no child. A non-NULL value contains exactly its
    # wrapped child as elements[0], while retaining the Nullable nominal type.
    def self.nullable(type : BinaryDataType, child : BinaryValue? = nil) : BinaryValue
      unless type.tag == BinaryDataType::TAG_NULLABLE
        raise ArgumentError.new("nullable value requires Nullable type")
      end
      if child
        unless child.type == type.child_at(0)
          raise ArgumentError.new("Nullable child type does not match its descriptor")
        end
        if child.type.tag == BinaryDataType::TAG_NOTHING && child.is_null?
          raise ArgumentError.new("Nullable(Nothing) cannot wrap the dynamic Nothing NULL sentinel")
        end
        new(type, nil, [child] of BinaryValue, false)
      else
        new(type, nil, [] of BinaryValue, true)
      end
    end

    # LowCardinality is nominal in this logical value tree, but its row-value
    # payload is exactly one value of the declared nested type. Dictionary and
    # index streams belong to a separate physical serializer owner.
    def self.low_cardinality(type : BinaryDataType, child : BinaryValue) : BinaryValue
      unless type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        raise ArgumentError.new("LowCardinality value requires LowCardinality type")
      end
      unless child.type == type.child_at(0)
        raise ArgumentError.new("LowCardinality child type does not match its descriptor")
      end
      new(type, nil, [child] of BinaryValue)
    end

    # SimpleAggregateFunction is nominal but has no row-value framing: its
    # UInt64 storage value remains one typed child in the logical tree.
    def self.simple_aggregate(type : BinaryDataType, child : BinaryValue) : BinaryValue
      unless type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE
        raise ArgumentError.new("SimpleAggregateFunction value requires SimpleAggregateFunction type")
      end
      unless child.type == type.child_at(0)
        raise ArgumentError.new("SimpleAggregateFunction child type does not match its descriptor")
      end
      new(type, nil, [child] of BinaryValue)
    end

    def self.tuple(type : BinaryDataType, fields : Array(BinaryValue)) : BinaryValue
      unless type.tag == BinaryDataType::TAG_UNNAMED_TUPLE || type.tag == BinaryDataType::TAG_NAMED_TUPLE
        raise ArgumentError.new("tuple value requires Tuple type")
      end
      unless fields.size == type.child_count
        raise ArgumentError.new("Tuple field count does not match its descriptor")
      end
      fields.each_with_index do |field, index|
        unless field.type == type.child_at(index)
          raise ArgumentError.new("Tuple field type does not match its descriptor")
        end
      end
      new(type, nil, fields)
    end

    # Maps preserve wire/order semantics as a flat alternating key/value list.
    def self.map(type : BinaryDataType, flat_values : Array(BinaryValue)) : BinaryValue
      unless type.tag == BinaryDataType::TAG_MAP
        raise ArgumentError.new("map value requires Map type")
      end
      unless flat_values.size.even?
        raise ArgumentError.new("Map values must contain complete key/value pairs")
      end
      flat_values.each_with_index do |value, index|
        expected = type.child_at(index.even? ? 0 : 1)
        unless value.type == expected
          raise ArgumentError.new("Map entry type does not match its descriptor")
        end
      end
      new(type, nil, flat_values)
    end

    # A detached payload snapshot. Container values have no scalar payload.
    def bytes : Bytes
      return @qbit_value.not_nil!.raw_bytes if @qbit_value
      payload = @payload || raise ArgumentError.new("value has no scalar byte payload")
      Bytes.new(payload.size) { |index| payload[index] }
    end

    # Cheap size for preflight checks. It excludes any VarUInt/string header.
    def byte_size : Int32
      return @qbit_value.not_nil!.raw_bytesize if @qbit_value
      @payload.try(&.size) || 0
    end

    def byte_at(index : Int) : UInt8
      if value = @qbit_value
        if index < 0 || index >= value.raw_bytesize
          raise IndexError.new("QBit raw byte index is outside the row")
        end
        return value.raw_byte_at(index.to_i32)
      end
      (@payload || raise ArgumentError.new("value has no scalar byte payload"))[index]
    end

    def qbit_value : QBitValue
      require_tag(BinaryDataType::TAG_QBIT, "QBit")
      @qbit_value || raise ArgumentError.new("QBit value has no owned raw row")
    end

    def json_row : BinaryJsonRow
      require_tag(BinaryDataType::TAG_JSON, "JSON")
      @json_row || raise ArgumentError.new("JSON value has no owned structured row")
    end

    def elements : Array(BinaryValue)
      @elements.dup
    end

    def element_count : Int32
      @elements.size
    end

    def child_count : Int32
      @elements.size
    end

    def element_at(index : Int) : BinaryValue
      @elements[index]
    end

    def child_at(index : Int) : BinaryValue
      @elements[index]
    end

    def is_null? : Bool
      @null
    end

    # QBit's owner supplies bit-exact equality. Preserve identity semantics for
    # the pre-existing non-QBit BinaryValue cases while supporting the newly
    # admitted QBit and Nullable(QBit) round trips.
    def ==(other : BinaryValue) : Bool
      return false unless @type == other.@type
      if @type.tag == BinaryDataType::TAG_JSON
        left = @json_row
        right = other.@json_row
        return left.nil? ? right.nil? : left == right
      end
      return same?(other) unless @type.contains_qbit?
      if @type.tag == BinaryDataType::TAG_QBIT
        return false unless @null == other.@null
        return true if @null
        return qbit_value == other.qbit_value
      else
        qbit_owned_tree_equal?(other)
      end
    end

    def hash(hasher)
      if @type.tag == BinaryDataType::TAG_JSON
        hasher = @type.hash(hasher)
        return @json_row.hash(hasher) if row = @json_row
        return hasher
      end
      unless @type.contains_qbit?
        return object_id.hash(hasher)
      end
      hasher = @type.hash(hasher)
      hasher = @null.hash(hasher)
      if @type.tag == BinaryDataType::TAG_QBIT && !@null
        return qbit_value.hash(hasher)
      end
      qbit_owned_tree_hash(hasher)
    end

    # A QBit-bearing parent opts into structural comparison for its complete
    # value subtree. Ordinary roots intentionally retain object-identity
    # semantics; do not call their public == recursively because that would
    # restore the very identity mismatch this scoped owner handles.
    private def qbit_owned_tree_equal?(other : BinaryValue) : Bool
      pending = Array(Tuple(BinaryValue, BinaryValue)).new
      pending << {self, other}

      until pending.empty?
        left, right = pending.pop
        return false unless left.@type == right.@type
        return false unless left.@null == right.@null
        return false unless left.@variant_index == right.@variant_index
        return false unless exact_payload_equal?(left.@payload, right.@payload)

        left_qbit = left.@qbit_value
        right_qbit = right.@qbit_value
        return false unless left_qbit.nil? == right_qbit.nil?
        if left_value = left_qbit
          return false unless left_value == right_qbit.not_nil!
        end

        left_json = left.@json_row
        right_json = right.@json_row
        return false unless left_json.nil? == right_json.nil?
        if left_row = left_json
          right_row = right_json.not_nil!
          return false unless left_row.type == right_row.type && left_row.path_count == right_row.path_count
          left_row.path_count.times do |index|
            return false unless exact_json_path_equal?(left_row, right_row, index)
          end
          index = left_row.path_count - 1
          while index >= 0
            pending << {left_row.value_at(index), right_row.value_at(index)}
            index -= 1
          end
        else
          return false unless left.@elements.size == right.@elements.size
          index = left.@elements.size - 1
          while index >= 0
            pending << {left.@elements[index], right.@elements[index]}
            index -= 1
          end
        end
      end
      true
    end

    # Hash with the same scoped value grammar used by qbit_owned_tree_equal?.
    # Include raw payload bytes and explicit child counts so exact float bits,
    # NULL placement, Variant discriminators, JSON paths, and child order all
    # contribute without changing standalone ordinary-value hashing.
    private def qbit_owned_tree_hash(hasher)
      pending = Array(BinaryValue).new
      pending << self

      until pending.empty?
        value = pending.pop
        hasher = value.@type.hash(hasher)
        hasher = value.@null.hash(hasher)
        hasher = value.@variant_index.hash(hasher)

        payload = value.@payload
        hasher = payload.nil?.hash(hasher)
        if bytes = payload
          hasher = bytes.size.hash(hasher)
          bytes.each { |byte| hasher = byte.hash(hasher) }
        end

        qbit = value.@qbit_value
        hasher = qbit.nil?.hash(hasher)
        hasher = qbit.hash(hasher) if qbit

        row = value.@json_row
        hasher = row.nil?.hash(hasher)
        if json = row
          hasher = json.path_count.hash(hasher)
          json.path_count.times do |index|
            path_size = json.path_byte_size(index)
            hasher = path_size.hash(hasher)
            path_size.times do |byte_index|
              hasher = json.path_byte_at(index, byte_index).hash(hasher)
            end
          end
          index = json.path_count - 1
          while index >= 0
            pending << json.value_at(index)
            index -= 1
          end
        else
          hasher = value.@elements.size.hash(hasher)
          index = value.@elements.size - 1
          while index >= 0
            pending << value.@elements[index]
            index -= 1
          end
        end
      end
      hasher
    end

    private def exact_payload_equal?(left : Bytes?, right : Bytes?) : Bool
      left_bytes = left
      right_bytes = right
      return right_bytes.nil? unless left_bytes
      return false unless right_bytes
      return false unless left_bytes.size == right_bytes.size
      left_bytes.size.times { |index| return false unless left_bytes[index] == right_bytes[index] }
      true
    end

    private def exact_json_path_equal?(left : BinaryJsonRow, right : BinaryJsonRow, index : Int) : Bool
      size = left.path_byte_size(index)
      return false unless size == right.path_byte_size(index)
      size.times { |byte_index| return false unless left.path_byte_at(index, byte_index) == right.path_byte_at(index, byte_index) }
      true
    end

    def variant_index? : UInt8?
      require_tag(BinaryDataType::TAG_VARIANT, "Variant")
      @variant_index
    end

    def variant_child? : BinaryValue?
      require_tag(BinaryDataType::TAG_VARIANT, "Variant")
      @variant_index.nil? ? nil : @elements[0]?
    end

    def as_string : String
      require_tag(BinaryDataType::TAG_STRING, "String")
      payload = @payload.not_nil!
      String.new(Bytes.new(payload.size) { |index| payload[index] })
    end

    def as_bool : Bool
      require_tag(BinaryDataType::TAG_BOOL, "Bool")
      BoolValueCodec.decode(@payload.not_nil![0])
    end

    def as_int64 : Int64
      require_tag(BinaryDataType::TAG_INT64, "Int64")
      read_le_u64.unsafe_as(Int64)
    end

    def as_interval_count : Int64
      require_tag(BinaryDataType::TAG_INTERVAL, "Interval")
      read_le_u64.unsafe_as(Int64)
    end

    def as_uint64 : UInt64
      require_tag(BinaryDataType::TAG_UINT64, "UInt64")
      read_le_u64
    end

    def count_state : UInt64
      require_tag(BinaryDataType::TAG_AGGREGATE_FUNCTION, "AggregateFunction(count)")
      unless @type.aggregate_count_type
        raise ArgumentError.new("value is not an AggregateFunction(count) state")
      end
      read_le_u64
    end

    def aggregate_function_state_bytes : Bytes
      require_tag(BinaryDataType::TAG_AGGREGATE_FUNCTION, "AggregateFunction")
      descriptor = @type.aggregate_function_type || raise ArgumentError.new("AggregateFunction metadata is missing")
      if descriptor.function_name == "count" || @type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) uses its compatibility carrier")
      end
      payload = @payload || raise ArgumentError.new("AggregateFunction state payload is missing")
      Bytes.new(payload.size) { |index| payload[index] }
    end

    def as_simple_aggregate : BinaryValue
      require_tag(BinaryDataType::TAG_SIMPLE_AGGREGATE, "SimpleAggregateFunction")
      @elements[0]
    end

    def as_float32_bits : UInt32
      require_tag(BinaryDataType::TAG_FLOAT32, "Float32")
      read_le_u32
    end

    def as_float64_bits : UInt64
      require_tag(BinaryDataType::TAG_FLOAT64, "Float64")
      read_le_u64
    end

    private def read_le_u32 : UInt32
      payload = @payload.not_nil!
      value = 0_u32
      4.times do |index|
        value |= payload[index].to_u32 << (index * 8)
      end
      value
    end

    private def read_le_u64 : UInt64
      payload = @payload.not_nil!
      value = 0_u64
      8.times do |index|
        value |= payload[index].to_u64 << (index * 8)
      end
      value
    end

    private def require_tag(tag : UInt8, expected : String) : Nil
      unless @type.tag == tag
        raise ArgumentError.new("value is not #{expected}")
      end
    end

    private def self.validate_children(expected : BinaryDataType, values : Array(BinaryValue)) : Nil
      values.each do |value|
        unless value.type == expected
          raise ArgumentError.new("container child type does not match its descriptor")
        end
      end
    end

    private def self.little_endian(value : UInt64, width : Int) : Bytes
      Bytes.new(width) do |index|
        ((value >> (index * 8)) & 0xff_u64).to_u8
      end
    end
  end
end
