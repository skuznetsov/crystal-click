module CrystalClick
  # Physical framing selected for Compact Variant discriminator callbacks.
  # ClickHouse's Compact serializer default is COMPACT; BASIC remains
  # available for explicit compatibility fixtures.
  enum CompactVariantDiscriminatorMode : UInt64
    Basic   = 0
    Compact = 1

    def wire_value : UInt64
      case self.value
      when 0 then DynamicDiscriminatorBodyValidator::BASIC_MODE
      when 1 then DynamicDiscriminatorBodyValidator::COMPACT_MODE
      else
        raise UnsupportedFormatError.new("unknown Compact Variant discriminator mode")
      end
    end
  end
end
