module CrystalClick
  # The closed set of exact primitive numeric identities admitted as named
  # Tuple leaves. This owns nominal names and widths, not byte codecs.
  module WideTupleNumericType
    alias Value = Int8 | UInt8 | Int16 | UInt16 | Int32 | UInt32 | Int64 | UInt64 |
                  Int128 | UInt128 | Int256Value | UInt256Value | Float32 | Float64 | BFloat16Value

    alias Buffer = Array(Int8) | Array(UInt8) | Array(Int16) | Array(UInt16) |
                   Array(Int32) | Array(UInt32) | Array(Int64) | Array(UInt64) |
                   Array(Int128) | Array(UInt128) | Array(Int256Value) | Array(UInt256Value) |
                   Array(Float32) | Array(Float64) | Array(BFloat16Value)

    def self.width(type_name : String) : Int32?
      case type_name
      when "Int8", "UInt8"
        1
      when "Int16", "UInt16", "BFloat16"
        2
      when "Int32", "UInt32", "Float32"
        4
      when "Int64", "UInt64", "Float64"
        8
      when "Int128", "UInt128"
        16
      when "Int256", "UInt256"
        32
      else
        nil
      end
    end

    def self.type_name(type : T.class) : String forall T
      {% if T == Int8 %}
        owned_name("Int8")
      {% elsif T == UInt8 %}
        owned_name("UInt8")
      {% elsif T == Int16 %}
        owned_name("Int16")
      {% elsif T == UInt16 %}
        owned_name("UInt16")
      {% elsif T == Int32 %}
        owned_name("Int32")
      {% elsif T == UInt32 %}
        owned_name("UInt32")
      {% elsif T == Int64 %}
        owned_name("Int64")
      {% elsif T == UInt64 %}
        owned_name("UInt64")
      {% elsif T == Int128 %}
        owned_name("Int128")
      {% elsif T == UInt128 %}
        owned_name("UInt128")
      {% elsif T == Int256Value %}
        owned_name("Int256")
      {% elsif T == UInt256Value %}
        owned_name("UInt256")
      {% elsif T == Float32 %}
        owned_name("Float32")
      {% elsif T == Float64 %}
        owned_name("Float64")
      {% elsif T == BFloat16Value %}
        owned_name("BFloat16")
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      {% end %}
    end

    def self.type_name_for_buffer(buffer : Buffer) : String
      if buffer.is_a?(Array(Int8))
        owned_name("Int8")
      elsif buffer.is_a?(Array(UInt8))
        owned_name("UInt8")
      elsif buffer.is_a?(Array(Int16))
        owned_name("Int16")
      elsif buffer.is_a?(Array(UInt16))
        owned_name("UInt16")
      elsif buffer.is_a?(Array(Int32))
        owned_name("Int32")
      elsif buffer.is_a?(Array(UInt32))
        owned_name("UInt32")
      elsif buffer.is_a?(Array(Int64))
        owned_name("Int64")
      elsif buffer.is_a?(Array(UInt64))
        owned_name("UInt64")
      elsif buffer.is_a?(Array(Int128))
        owned_name("Int128")
      elsif buffer.is_a?(Array(UInt128))
        owned_name("UInt128")
      elsif buffer.is_a?(Array(Int256Value))
        owned_name("Int256")
      elsif buffer.is_a?(Array(UInt256Value))
        owned_name("UInt256")
      elsif buffer.is_a?(Array(Float32))
        owned_name("Float32")
      elsif buffer.is_a?(Array(Float64))
        owned_name("Float64")
      elsif buffer.is_a?(Array(BFloat16Value))
        owned_name("BFloat16")
      else
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf buffer")
      end
    end

    def self.width(type : T.class) : Int32 forall T
      {% if T == Int8 || T == UInt8 %}
        1
      {% elsif T == Int16 || T == UInt16 || T == BFloat16Value %}
        2
      {% elsif T == Int32 || T == UInt32 || T == Float32 %}
        4
      {% elsif T == Int64 || T == UInt64 || T == Float64 %}
        8
      {% elsif T == Int128 || T == UInt128 %}
        16
      {% elsif T == Int256Value || T == UInt256Value %}
        32
      {% else %}
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      {% end %}
    end

    # Compare the exact nominal values represented by the persisted bytes.
    # Floating-point values are compared as raw bits so signed zero and NaN
    # payload distinctions remain observable.
    def self.same_bits?(left : Value, right : Value) : Bool
      if left.is_a?(Int8) && right.is_a?(Int8)
        left == right
      elsif left.is_a?(UInt8) && right.is_a?(UInt8)
        left == right
      elsif left.is_a?(Int16) && right.is_a?(Int16)
        left == right
      elsif left.is_a?(UInt16) && right.is_a?(UInt16)
        left == right
      elsif left.is_a?(Int32) && right.is_a?(Int32)
        left == right
      elsif left.is_a?(UInt32) && right.is_a?(UInt32)
        left == right
      elsif left.is_a?(Int64) && right.is_a?(Int64)
        left == right
      elsif left.is_a?(UInt64) && right.is_a?(UInt64)
        left == right
      elsif left.is_a?(Int128) && right.is_a?(Int128)
        left == right
      elsif left.is_a?(UInt128) && right.is_a?(UInt128)
        left == right
      elsif left.is_a?(Int256Value) && right.is_a?(Int256Value)
        left.low == right.low && left.high == right.high
      elsif left.is_a?(UInt256Value) && right.is_a?(UInt256Value)
        left.low == right.low && left.high == right.high
      elsif left.is_a?(Float32) && right.is_a?(Float32)
        left.unsafe_as(UInt32) == right.unsafe_as(UInt32)
      elsif left.is_a?(Float64) && right.is_a?(Float64)
        left.unsafe_as(UInt64) == right.unsafe_as(UInt64)
      elsif left.is_a?(BFloat16Value) && right.is_a?(BFloat16Value)
        left.bits == right.bits
      else
        false
      end
    end

    # Pinned stock Tuple observations treat the sampled numeric defaults as
    # raw all-zero bits (including Float -0.0 as non-default). This helper is
    # intentionally limited to those exact primitive identities.
    def self.is_default?(value : Value) : Bool
      if value.is_a?(Int8) || value.is_a?(Int16) || value.is_a?(Int32) ||
         value.is_a?(Int64) || value.is_a?(Int128)
        value == 0
      elsif value.is_a?(UInt8) || value.is_a?(UInt16) || value.is_a?(UInt32) ||
            value.is_a?(UInt64) || value.is_a?(UInt128)
        value == 0
      elsif value.is_a?(Int256Value) || value.is_a?(UInt256Value)
        value.low == 0_u128 && value.high == 0_u128
      elsif value.is_a?(Float32)
        value.unsafe_as(UInt32) == 0_u32
      elsif value.is_a?(Float64)
        value.unsafe_as(UInt64) == 0_u64
      elsif value.is_a?(BFloat16Value)
        value.bits == 0_u16
      else
        false
      end
    end

    private def self.owned_name(name : String) : String
      String.new(name.to_slice)
    end
  end
end
