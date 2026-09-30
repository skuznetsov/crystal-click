module CrystalClick
  # The closed nominal identifier/address identities admitted as compositional
  # Tuple leaves. Their raw widths are shared with numeric fields only for
  # accounting; the wrapper types are never relabeled as integers.
  module WideTupleIdentifierType
    alias Value = UUIDValue | IPv4Value | IPv6Value

    alias Buffer = Array(UUIDValue) | Array(IPv4Value) | Array(IPv6Value)

    def self.width(type_name : String) : Int32?
      case type_name
      when "UUID", "IPv6"
        16
      when "IPv4"
        4
      else
        nil
      end
    end

    def self.width(type : T.class) : Int32 forall T
      {% if T == UUIDValue || T == IPv6Value %}
        16
      {% elsif T == IPv4Value %}
        4
      {% else %}
        raise UnsupportedFormatError.new("unsupported identifier Tuple leaf type")
      {% end %}
    end

    def self.type_name(type : T.class) : String forall T
      {% if T == UUIDValue %}
        owned_name("UUID")
      {% elsif T == IPv4Value %}
        owned_name("IPv4")
      {% elsif T == IPv6Value %}
        owned_name("IPv6")
      {% else %}
        raise UnsupportedFormatError.new("unsupported identifier Tuple leaf type")
      {% end %}
    end

    def self.type_name_for_buffer(buffer : Buffer) : String
      if buffer.is_a?(Array(UUIDValue))
        owned_name("UUID")
      elsif buffer.is_a?(Array(IPv4Value))
        owned_name("IPv4")
      else
        owned_name("IPv6")
      end
    end

    # Exact raw identity comparison; same-width cross-type wrappers never
    # compare equal through this owner.
    def self.same_bits?(left : Value, right : Value) : Bool
      if left.is_a?(UUIDValue) && right.is_a?(UUIDValue)
        left.high == right.high && left.low == right.low
      elsif left.is_a?(IPv4Value) && right.is_a?(IPv4Value)
        left.network_order == right.network_order
      elsif left.is_a?(IPv6Value) && right.is_a?(IPv6Value)
        left.high == right.high && left.low == right.low
      else
        false
      end
    end

    # Qualified stock-created Tuple defaults are the all-zero raw wrapper
    # values for this family. This predicate does not reinterpret addresses.
    def self.is_default?(value : Value) : Bool
      if value.is_a?(UUIDValue) || value.is_a?(IPv6Value)
        value.high == 0_u64 && value.low == 0_u64
      else
        value.as(IPv4Value).network_order == 0_u32
      end
    end

    private def self.owned_name(name : String) : String
      String.new(name.to_slice)
    end
  end
end
