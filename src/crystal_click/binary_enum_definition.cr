require "set"

module CrystalClick
  # Immutable signed-code-ordered Enum table. Labels are opaque byte strings:
  # they are copied at construction and exposed only through detached copies.
  class BinaryEnumDefinition
    alias Entry = Tuple(String, Int16)

    MAX_ENUM8_ENTRIES  =    256
    MAX_ENUM16_ENTRIES = 65_536

    getter width_bits : Int32

    @entries : Array(Entry)

    def initialize(width_bits : Int, entries : Array(Entry))
      maximum, minimum_code, maximum_code = case width_bits
                                            when  8 then {MAX_ENUM8_ENTRIES, -128_i32, 127_i32}
                                            when 16 then {MAX_ENUM16_ENTRIES, -32_768_i32, 32_767_i32}
                                            else
                                              raise ArgumentError.new("binary Enum width must be 8 or 16 bits")
                                            end
      raise ArgumentError.new("binary Enum definition cannot be empty") if entries.empty?
      if entries.size > maximum
        raise ArgumentError.new("binary Enum definition exceeds its signed code domain")
      end

      labels = Set(String).new
      codes = Set(Int16).new
      owned = Array(Entry).new(entries.size)
      entries.each do |label, code|
        if code.to_i32 < minimum_code || code.to_i32 > maximum_code
          raise ArgumentError.new("binary Enum code is outside its signed width")
        end
        raise ArgumentError.new("binary Enum labels must be unique") unless labels.add?(label)
        raise ArgumentError.new("binary Enum codes must be unique") unless codes.add?(code)
        owned << {String.new(label.to_slice), code}
      end

      @width_bits = width_bits.to_i32
      @entries = owned.sort_by { |entry| entry[1] }
    end

    def size : Int32
      @entries.size
    end

    def entry_at(index : Int) : Entry
      label, code = @entries[index]
      {String.new(label.to_slice), code}
    end

    def entries : Array(Entry)
      @entries.map { |label, code| {String.new(label.to_slice), code} }
    end

    def type_name : String
      String.build do |io|
        io << (@width_bits == 8 ? "Enum8(" : "Enum16(")
        @entries.each_with_index do |entry, index|
          io << ", " unless index == 0
          io << '\''
          write_escaped_label(io, entry[0])
          io << "' = " << entry[1]
        end
        io << ')'
      end
    end

    def label_byte_size(index : Int) : Int32
      @entries[index][0].bytesize
    end

    def label_byte_at(index : Int, byte_index : Int) : UInt8
      @entries[index][0].to_slice[byte_index]
    end

    def code_at(index : Int) : Int16
      @entries[index][1]
    end

    def ==(other : self) : Bool
      return false unless @width_bits == other.@width_bits && @entries.size == other.@entries.size
      @entries.each_with_index.all? do |entry, index|
        other_entry = other.@entries[index]
        entry[0] == other_entry[0] && entry[1] == other_entry[1]
      end
    end

    def hash(hasher)
      hasher = @width_bits.hash(hasher)
      @entries.each do |label, code|
        hasher = label.hash(hasher)
        hasher = code.hash(hasher)
      end
      hasher
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
