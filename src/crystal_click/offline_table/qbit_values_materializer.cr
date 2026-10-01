module CrystalClick
  # Whole-column QBit materialization budget. The selected values are appended
  # into Array(OfflineColumnValue), so charge the real union slot width in
  # addition to retained raw row bytes before that whole-column array exists.
  class QBitValuesMaterializer
    def self.checked_expected_charge(rows : UInt64, plan : QBitColumnType) : UInt64
      slot_bytes = sizeof(OfflineColumnValue).to_u64
      row_bytes = plan.value_type.raw_row_bytes.to_u64
      per_row = checked_add(slot_bytes, row_bytes)
      descriptor_bytes = plan.value_type.type_name.bytesize.to_u64 + 64_u64
      if rows > (UInt64::MAX - descriptor_bytes) // per_row
        raise BoundsError.new("selected QBit column materialization charge overflows")
      end
      charge = descriptor_bytes + rows * per_row
      if charge > QBitColumnType::MAX_MATERIALIZED_BYTES
        raise BoundsError.new("selected QBit column materialization exceeds 64 MiB limit")
      end
      charge
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("selected QBit column materialization charge overflows") if left > UInt64::MAX - right
      left + right
    end
  end
end
