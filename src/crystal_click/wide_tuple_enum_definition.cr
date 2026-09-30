module CrystalClick
  # Immutable, sorted Enum label/code bijection shared by an exact Tuple leaf
  # descriptor and all of its row wrappers.
  class WideTupleEnumDefinition
    alias Entry = Tuple(String, Int16)
    MAX_ENTRY_COUNT                 =       509
    MAX_CANONICAL_DECLARATION_BYTES = 4_096_u64

    @kind : Symbol
    @entries : Array(Entry)
    @type_name : String

    def initialize(kind : Symbol, entries : Array(Entry))
      minimum, maximum = case kind
                         when :enum8  then {-128_i32, 127_i32}
                         when :enum16 then {-32_768_i32, 32_767_i32}
                         else
                           raise ArgumentError.new("Enum kind must be :enum8 or :enum16")
                         end
      raise ArgumentError.new("Enum definition cannot be empty") if entries.empty?
      if entries.size > MAX_ENTRY_COUNT
        raise ArgumentError.new("Enum definition exceeds #{MAX_ENTRY_COUNT} entries")
      end

      # Bound the canonical declaration before allocating duplicate-detection
      # Sets, owned label strings, the sorted entry array, or the cached name.
      preflight_declaration!(kind, entries, minimum, maximum)

      labels = Set(String).new
      codes = Set(Int16).new
      owned = Array(Entry).new(entries.size)
      entries.each do |label, code|
        raise ArgumentError.new("Enum label is duplicated") unless labels.add?(label)
        raise ArgumentError.new("Enum code is duplicated") unless codes.add?(code)
        owned << {String.new(label.to_slice), code}
      end

      @kind = kind
      sorted = owned.sort_by { |entry| entry[1] }
      # Allocate the retained array at its final size and fill it once; the
      # construction keeps its capacity equal to this immutable entry count.
      @entries = Array(Entry).new(sorted.size)
      sorted.each { |entry| @entries << entry }
      @type_name = build_type_name
    end

    def kind : Symbol
      @kind
    end

    def entries : Array(Entry)
      @entries.map { |label, code| {String.new(label.to_slice), code} }
    end

    def size : Int32
      @entries.size
    end

    def declared?(code : Int8) : Bool
      return false unless @kind == :enum8
      !entry_for_code(code.to_i16).nil?
    end

    def declared?(code : Int16) : Bool
      return false if @kind == :enum8
      !entry_for_code(code).nil?
    end

    def label_for(code : Int8) : String?
      return nil unless @kind == :enum8
      entry_for_code(code.to_i16).try { |entry| String.new(entry[0].to_slice) }
    end

    def label_for(code : Int16) : String?
      return nil if @kind == :enum8
      entry_for_code(code).try { |entry| String.new(entry[0].to_slice) }
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    # Count every retained heap instance and payload: definition, entry Array,
    # entry slots, each label String and bytes, and cached declaration String
    # and bytes. Temporary validation Sets are not retained and are not charged.
    def logical_charge : UInt64
      total = instance_sizeof(WideTupleEnumDefinition).to_u64
      total += instance_sizeof(Array(Entry)).to_u64
      total += (@entries.size.to_u64 * sizeof(Entry).to_u64)
      @entries.each do |label, _code|
        total += instance_sizeof(String).to_u64 + label.bytesize.to_u64 + 1_u64
      end
      total + instance_sizeof(String).to_u64 + @type_name.bytesize.to_u64 + 1_u64
    end

    def ==(other : self) : Bool
      return false unless @kind == other.@kind && @entries.size == other.@entries.size
      @entries.each_with_index.all? do |entry, index|
        other_entry = other.@entries[index]
        entry[1] == other_entry[1] && entry[0] == other_entry[0]
      end
    end

    def hash(hasher)
      hasher = @kind.hash(hasher)
      @entries.each do |label, code|
        hasher = label.hash(hasher)
        hasher = code.hash(hasher)
      end
      hasher
    end

    private def entry_for_code(code : Int16) : Entry?
      low = 0
      high = @entries.size - 1
      while low <= high
        middle = (low + high) // 2
        entry = @entries[middle]
        if entry[1] == code
          return entry
        elsif entry[1] < code
          low = middle + 1
        else
          high = middle - 1
        end
      end
      nil
    end

    private def preflight_declaration!(kind : Symbol, entries : Array(Entry), minimum : Int32, maximum : Int32) : Nil
      # Include the EnumN( prefix and closing parenthesis once. Per entry, the
      # canonical emitter writes two label quotes, " = ", the decimal code,
      # and (except for the first entry) a comma-space separator.
      canonical_bytes = kind == :enum8 ? 7_u64 : 8_u64
      entries.each_with_index do |entry, index|
        label, code = entry
        if code.to_i32 < minimum || code.to_i32 > maximum
          raise ArgumentError.new("Enum code is outside its signed width")
        end

        canonical_bytes += 5_u64 + decimal_code_bytesize(code).to_u64
        canonical_bytes += 2_u64 unless index == 0
        raise_declaration_size_error! if canonical_bytes > MAX_CANONICAL_DECLARATION_BYTES

        label.to_slice.each do |byte|
          if (byte < 0x20_u8 && byte != 0x00_u8 && byte != 0x08_u8 && byte != 0x09_u8 &&
             byte != 0x0a_u8 && byte != 0x0c_u8 && byte != 0x0d_u8) || byte == 0x7f_u8
            raise ArgumentError.new("Enum label contains an unsupported raw control byte")
          end
          canonical_bytes += escaped_label_byte?(byte) ? 2_u64 : 1_u64
          raise_declaration_size_error! if canonical_bytes > MAX_CANONICAL_DECLARATION_BYTES
        end
      end
      nil
    end

    private def raise_declaration_size_error! : NoReturn
      raise ArgumentError.new("Enum canonical declaration exceeds #{MAX_CANONICAL_DECLARATION_BYTES} bytes")
    end

    private def decimal_code_bytesize(code : Int16) : Int32
      value = code.to_i32
      count = 0
      if value < 0
        count += 1
        value = -value
      end
      loop do
        count += 1
        value = value // 10
        break if value == 0
      end
      count
    end

    private def escaped_label_byte?(byte : UInt8) : Bool
      byte == 0x00_u8 || byte == 0x08_u8 || byte == 0x09_u8 || byte == 0x0a_u8 ||
        byte == 0x0c_u8 || byte == 0x0d_u8 || byte == 0x27_u8 || byte == 0x5c_u8
    end

    private def build_type_name : String
      String.build do |io|
        io << (@kind == :enum8 ? "Enum8(" : "Enum16(")
        @entries.each_with_index do |entry, index|
          io << ", " unless index == 0
          io << '\''
          write_escaped_label(io, entry[0])
          io << "' = " << entry[1]
        end
        io << ')'
      end
    end

    private def write_escaped_label(io : IO, label : String) : Nil
      label.to_slice.each do |byte|
        case byte
        when 0x00_u8 then io << "\\0"
        when 0x08_u8 then io << "\\b"
        when 0x09_u8 then io << "\\t"
        when 0x0a_u8 then io << "\\n"
        when 0x0c_u8 then io << "\\f"
        when 0x0d_u8 then io << "\\r"
        when 0x27_u8 then io << "\\'"
        when 0x5c_u8 then io << "\\\\"
        else
          io.write_byte(byte)
        end
      end
      nil
    end
  end
end
