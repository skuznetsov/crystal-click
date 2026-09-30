module CrystalClick
  # A syntax-only, bounded storage plan for named Tuples with exact UInt64 and
  # String leaves. This plan does not by itself admit a persisted part profile.
  class WideTupleTypePlan
    MAX_FIELD_NAME_BYTES   = 128
    MAX_MATERIALIZED_BYTES = 64_u64 * 1024_u64 * 1024_u64

    RESULT_CONTAINER_ACCOUNTING_BYTES = 64_u64
    FIELD_CONTAINER_ACCOUNTING_BYTES  = 24_u64
    RESULT_ROW_ACCOUNTING_BYTES       =  8_u64
    UINT64_SLOT_ACCOUNTING_BYTES      =  8_u64
    STRING_SLOT_ACCOUNTING_BYTES      = 16_u64

    @type_name : String
    @fields : Array(WideTupleField)

    private def initialize(@type_name : String, fields : Array(WideTupleField))
      @type_name = String.new(@type_name.to_slice)
      @fields = fields.dup
    end

    def self.for_type(type : String) : WideTupleTypePlan?
      # The shared syntax tree does not retain whether a scalar child was
      # written as `String` or `String()`. This profile admits only the exact
      # bare scalar spellings, so reject empty-argument aliases locally.
      return nil if /\b(?:UInt64|String)\s*\(\s*\)/.matches?(type)
      node = WideTypeExpression.parse(type) || return nil
      return nil unless node.name == "Tuple" && node.children.size > 0

      names = node.field_names
      return nil unless names.size == node.children.size

      fields = Array(WideTupleField).new(names.size)
      seen = Set(String).new
      node.children.each_with_index do |child, index|
        name = names[index]
        return nil unless valid_field_name?(name)
        return nil unless seen.add?(name)
        return nil unless child.children.empty? && (child.name == "UInt64" || child.name == "String")
        fields << WideTupleField.new(name, child.name)
      end

      canonical = "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
      new(canonical, fields)
    end

    private def self.valid_field_name?(name : String) : Bool
      return false if name.empty? || name.bytesize > MAX_FIELD_NAME_BYTES || name == "null"
      bytes = name.to_slice
      return false unless identifier_start?(bytes[0])
      bytes[1, bytes.size - 1].each do |byte|
        return false unless identifier_continue?(byte)
      end
      true
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      byte == '_'.ord.to_u8 ||
        (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8)
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def fields : Array(WideTupleField)
      @fields.map { |field| WideTupleField.new(field.name, field.type_name) }
    end

    def physical_streams(column : String) : Array(String)
      streams = Array(String).new
      @fields.each do |field|
        leaf_stream = leaf_stream_name(column, field)
        if field.type_name == "String"
          streams << "#{leaf_stream}.size"
        end
        streams << leaf_stream
      end
      streams
    end

    def raw_string_stream?(column : String, stream_name : String) : Bool
      @fields.any? do |field|
        field.type_name == "String" && leaf_stream_name(column, field) == stream_name
      end
    end

    def stream_width(column : String, stream_name : String) : Int32?
      @fields.each do |field|
        leaf_stream = leaf_stream_name(column, field)
        if field.type_name == "String"
          return 8 if stream_name == "#{leaf_stream}.size"
          return 1 if stream_name == leaf_stream
        elsif stream_name == leaf_stream
          return 8
        end
      end
      nil
    end

    # Conservative logical charge shared by W94 readers and writers. It is
    # deliberately not an RSS estimate; nil means checked UInt64 arithmetic
    # overflowed before a caller can allocate, expose, or stage buffers.
    def materialization_charge(rows : UInt64, string_payload_bytes : UInt64) : UInt64?
      fixed_bytes = RESULT_CONTAINER_ACCOUNTING_BYTES
      field_bytes = @fields.size.to_u64 * FIELD_CONTAINER_ACCOUNTING_BYTES
      return nil if field_bytes > UInt64::MAX - fixed_bytes
      fixed_bytes += field_bytes

      row_bytes = RESULT_ROW_ACCOUNTING_BYTES
      @fields.each do |field|
        slot_bytes = field.type_name == "UInt64" ? UINT64_SLOT_ACCOUNTING_BYTES : STRING_SLOT_ACCOUNTING_BYTES
        return nil if slot_bytes > UInt64::MAX - row_bytes
        row_bytes += slot_bytes
      end
      return nil if rows > (UInt64::MAX - fixed_bytes) // row_bytes
      fixed_bytes += rows * row_bytes
      return nil if string_payload_bytes > UInt64::MAX - fixed_bytes
      fixed_bytes + string_payload_bytes
    end

    private def leaf_stream_name(column : String, field : WideTupleField) : String
      "#{column}%2E#{field.name}"
    end
  end
end
