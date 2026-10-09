module CrystalClick
  # Narrow admission fence for DataType nodes serialized inside shared Object
  # JSON envelopes. This policy is deliberately selected by only the paired
  # shared-envelope scalar entry points; default and specialized child codecs
  # retain their independent owner policies.
  module BinarySharedJsonEnvelopePolicy
    def self.check_data_type_tag!(context : BinaryCodecContext, tag : UInt8) : Nil
      message = case tag
                when BinaryDataType::TAG_DYNAMIC
                  return nil unless context.inside_shared_json_payload?
                  "Dynamic is not admitted in a shared JSON Object envelope"
                when BinaryDataType::TAG_VARIANT
                  "Variant is not admitted in a shared JSON Object envelope"
                when BinaryDataType::TAG_LOW_CARDINALITY
                  "LowCardinality is not admitted in a shared JSON Object envelope"
                when BinaryDataType::TAG_AGGREGATE_FUNCTION
                  "AggregateFunction is not admitted in a shared JSON Object envelope"
                when BinaryDataType::TAG_QBIT, BinaryDataType::TAG_QBIT_STRIDE
                  "QBit is not admitted in a shared JSON Object envelope"
                else
                  return nil
                end
      context.unsupported!(message)
    end
  end
end
