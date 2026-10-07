module CrystalClick
  # Inline actual-type envelope for a Dynamic value. This is deliberately an
  # internal companion to BinaryValueCodec: callbacks re-enter its private
  # value visitor with the same context and rebased depth.
  private class BinaryDynamicEnvelope
    def self.write(
      value : BinaryValue,
      context : BinaryCodecContext,
      depth : Int,
      &write_selected : BinaryValue, Int32 -> Nil
    ) : Nil
      if value.is_null?
        context.preflight_children(1_u64)
        BinaryDataTypeCodec.write_to(BinaryDataType.primitive("Nothing"), context, depth + 1)
      else
        selected = value.child_at(0)
        if selected.type.contains_qbit? && selected.type.tag != BinaryDataType::TAG_QBIT
          context.unsupported!("QBit is not admitted as a Dynamic actual type")
        end
        context.preflight_children(1_u64)
        BinaryDataTypeCodec.write_to(selected.type, context, depth + 1)
        context.preflight_children(1_u64)
        yield selected, depth + 1
      end
      nil
    end

    def self.read(
      type : BinaryDataType,
      context : BinaryCodecContext,
      depth : Int,
      &read_selected : BinaryDataType, Int32 -> BinaryValue
    ) : BinaryValue
      context.preflight_children(1_u64)
      selected_type = BinaryDataTypeCodec.read_from(context, depth + 1)
      if selected_type.contains_qbit? && selected_type.tag != BinaryDataType::TAG_QBIT
        context.unsupported!("QBit is not admitted as a Dynamic actual type")
      end
      if selected_type.tag == BinaryDataType::TAG_NOTHING
        BinaryValue.dynamic(type)
      else
        context.preflight_children(1_u64)
        selected = yield selected_type, depth + 1
        BinaryValue.dynamic(type, selected)
      end
    end
  end
end
