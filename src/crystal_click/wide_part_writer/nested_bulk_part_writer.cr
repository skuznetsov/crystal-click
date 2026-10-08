module CrystalClick
  module WidePartWriter
    # Nominal Nested adapter over the shared static part writer. Keep its
    # legacy tag guard, bounded name materialization, and profile checks ahead
    # of shared physical-role planning and output allocation.
    private class NestedBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      ) : String
        BinaryBulkPartWriter.write(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits, "Nested"
        ) do
          unless type.tag == BinaryDataType::TAG_NESTED
            raise UnsupportedFormatError.new("Nested bulk writer requires a nominal Nested descriptor")
          end

          name_budget = BinaryCodecBudget.new(limits, true)
          name_bounds = BinaryTypeNameBudget.measure(type, name_budget)
          canonical = BinaryTypeNameBudget.materialize(type, name_budget, name_bounds)
          name_budget.ensure_wire_bytes(name_bounds[1])
          name_budget.charge_wire_bytes(name_bounds[1])

          BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
          unless profile.single_stream? || profile.with_size_stream?
            raise UnsupportedFormatError.new("unsupported Nested String profile")
          end
          unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
            raise ArgumentError.new("Nested frame size is outside the compressed transport limit")
          end
          if granules.size > MAX_MARKS
            raise ArgumentError.new("Nested mark count exceeds writer limit")
          end
          canonical
        end
      end
    end
  end
end
