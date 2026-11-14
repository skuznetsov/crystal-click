module CrystalClick
  # Shared ordered UInt64 group-key snapshots and physical key carriers.
  module ProjectionUInt64Keys
    def self.snapshot(
      key_names : Array(String),
      key_columns : Array(Slice(UInt64)),
      rows_per_mark : Int32,
      aggregate_column_count : Int,
      max_physical_columns : Int,
      max_marks : Int32,
    ) : Tuple(Array(String), Array(Array(UInt64)))
      unless key_names.size > 0 && key_names.size == key_columns.size
        raise ArgumentError.new("aggregate projection key names and columns must share one nonempty roster")
      end
      unless key_names.to_set.size == key_names.size
        raise ArgumentError.new("aggregate projection key names must be distinct")
      end
      unless rows_per_mark > 0 && aggregate_column_count > 0
        raise ArgumentError.new("aggregate projection row grid or state roster is empty")
      end
      if key_names.size + aggregate_column_count > max_physical_columns
        raise ArgumentError.new("aggregate projection physical column count exceeds its format limit")
      end

      row_count = key_columns[0].size
      if row_count == 0 || row_count.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("aggregate projection key columns require a bounded nonempty row grid")
      end
      key_columns.each do |column|
        unless column.size == row_count
          raise ArgumentError.new("aggregate projection key columns must share one row grid")
        end
      end

      marks = mark_count(row_count, rows_per_mark, max_marks)
      PartWriterInfrastructure::PrimaryIndexWriter.compound_size(marks.to_i, key_columns.size)

      # Admit the detached UInt64 payload and key-name bytes before an O(rows)
      # ordering scan or any retained array/string allocation. This is a fresh
      # default logical payload budget, not an RSS bound.
      snapshot_bytes = snapshot_payload_bytes(row_count, key_names)
      if snapshot_bytes > CompressedStreamLimits.new.max_result_bytes
        raise ArgumentError.new("aggregate projection key snapshots exceed the 64 MiB default logical payload limit")
      end

      retained_names = key_names.map { |name| String.new(name.to_slice) }
      retained_columns = Array(Array(UInt64)).new(key_columns.size)
      key_columns.each do |column|
        values = Array(UInt64).new(row_count)
        column.each { |value| values << value }
        retained_columns << values
      end
      # Validate the values actually retained by the immutable projection.
      # The caller's slices may be mutable and must not be the certificate.
      validate_order!(retained_columns)
      {retained_names, retained_columns}
    end

    # Reserve all newly introduced Wide compound-key writer allocations in
    # one charge before the writer asks the projection for detached snapshots
    # or expands UInt64 lanes into BinaryValue carriers.
    def self.compound_writer_workspace_bytes(
      row_count : Int,
      key_count : Int,
      rows_per_mark : Int32,
      max_marks : Int32,
    ) : Int64
      unless row_count > 0 && row_count.to_u64 <= WidePart::MAX_ROWS &&
             key_count > 2 && key_count <= WidePart::MAX_METADATA_COLUMNS
        raise ArgumentError.new("compound projection writer workspace requires at least three bounded key lanes")
      end
      marks = mark_count(row_count, rows_per_mark, max_marks)
      rows = row_count.to_i64
      keys = key_count.to_i64
      additional_count = keys - 1_i64

      # The writer retains a copy of the primary lane and a detached roster
      # containing copies of every additional lane.
      snapshot_bytes = rows * keys * sizeof(UInt64).to_i64
      snapshot_bytes += instance_sizeof(Array(UInt64)).to_i64
      snapshot_bytes += instance_sizeof(Array(Array(UInt64))).to_i64
      snapshot_bytes += additional_count * (
        sizeof(Pointer(Array(UInt64))).to_i64 + instance_sizeof(Array(UInt64)).to_i64
      )

      snapshot_bytes + additional_key_carrier_workspace_bytes_at_marks(
        rows, additional_count, marks.to_i64
      )
    end

    # Logical result-byte charge for the two nested pointer grids retained
    # briefly during prepare, each BinaryValue object and its detached fixed
    # UInt64 payload, plus one shared type descriptor and encode scratch per
    # additional lane.
    def self.additional_key_carrier_workspace_bytes(
      row_count : Int,
      additional_key_count : Int,
      rows_per_mark : Int32,
      max_marks : Int32,
    ) : Int64
      unless row_count > 0 && row_count.to_u64 <= WidePart::MAX_ROWS &&
             additional_key_count >= 0 && additional_key_count < WidePart::MAX_METADATA_COLUMNS
        raise ArgumentError.new("compound projection carrier workspace dimensions are outside the admitted range")
      end
      return 0_i64 if additional_key_count == 0

      marks = mark_count(row_count, rows_per_mark, max_marks)
      additional_key_carrier_workspace_bytes_at_marks(
        row_count.to_i64, additional_key_count.to_i64, marks.to_i64
      )
    end

    # Constructor-only preflight for the newly added Compact array API. It
    # uses its own fresh default budget because no writer operation exists yet.
    def self.preflight_additional_key_carriers!(
      row_count : Int,
      additional_key_count : Int,
      rows_per_mark : Int32,
      max_marks : Int32,
    ) : Nil
      bytes = additional_key_carrier_workspace_bytes(
        row_count, additional_key_count, rows_per_mark, max_marks
      )
      if bytes > CompressedStreamLimits.new.max_result_bytes
        raise ArgumentError.new("aggregate projection additional UInt64 key columns exceed the 64 MiB default logical workspace limit")
      end
      nil
    end

    # Shared exact carrier builder. BinaryValue.fixed detaches the reusable
    # scratch bytes, and every value shares this immutable UInt64 descriptor.
    def self.uint64_granules(
      values : Array(UInt64),
      rows_per_mark : Int32,
      max_marks : Int32,
      type : BinaryDataType,
      aggregate_name : String,
    ) : Array(Array(BinaryValue))
      unless type.tag == BinaryDataType::TAG_UINT64
        raise ArgumentError.new("UInt64 key granules require the UInt64 descriptor")
      end
      unless !values.empty? && rows_per_mark > 0 && max_marks > 0
        raise ArgumentError.new("UInt64 key granules require a bounded nonempty row grid")
      end
      count = (values.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      unless count > 0 && count <= max_marks
        raise ArgumentError.new("#{aggregate_name} projection mark count is outside the writer limit")
      end
      marks = count.to_i32
      granules = Array(Array(BinaryValue)).new(marks)
      scratch = Bytes.new(sizeof(UInt64))
      offset = 0
      while offset < values.size
        rows = Math.min(rows_per_mark, values.size - offset)
        granules << Array(BinaryValue).new(rows) do |row|
          value = values[offset + row]
          IO::ByteFormat::LittleEndian.encode(value, scratch)
          BinaryValue.fixed(type, scratch)
        end
        offset += rows
      end
      granules
    end

    private def self.snapshot_payload_bytes(row_count : Int, key_names : Array(String)) : Int64
      bytes = row_count.to_i64 * key_names.size.to_i64 * sizeof(UInt64).to_i64
      key_names.each { |name| bytes += name.bytesize.to_i64 }
      bytes
    end

    private def self.mark_count(row_count : Int, rows_per_mark : Int32, max_marks : Int32) : Int32
      unless row_count > 0 && rows_per_mark > 0 && max_marks > 0
        raise ArgumentError.new("aggregate projection mark dimensions must be positive")
      end
      count = (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      unless count > 0 && count <= max_marks
        raise ArgumentError.new("aggregate projection mark count exceeds the admitted reader limit")
      end
      count.to_i32
    end

    private def self.validate_order!(key_columns : Array(Array(UInt64))) : Nil
      row_count = key_columns[0].size
      row = 1
      while row < row_count
        lane = 0
        while lane < key_columns.size
          current = key_columns[lane][row]
          previous = key_columns[lane][row - 1]
          if current > previous
            break
          elsif current < previous
            raise ArgumentError.new("aggregate projection key tuples must be strictly increasing lexicographically")
          end
          lane += 1
        end
        if lane == key_columns.size
          raise ArgumentError.new("aggregate projection key tuples must be strictly increasing lexicographically")
        end
        row += 1
      end
      nil
    end

    private def self.additional_key_carrier_workspace_bytes_at_marks(
      rows : Int64,
      additional_count : Int64,
      marks : Int64,
    ) : Int64
      return 0_i64 if additional_count == 0

      # A BinaryValue owns its inline fields, its detached eight-byte payload,
      # and the empty elements-array header copied by BinaryValue#initialize.
      # Each value appears in both the original and detached granule pointer
      # grids during prepare.
      per_value = instance_sizeof(BinaryValue).to_i64 + sizeof(UInt64).to_i64 +
                  instance_sizeof(Array(BinaryValue)).to_i64 +
                  2_i64 * sizeof(Pointer(BinaryValue)).to_i64
      per_lane = rows * per_value

      # Account for the two outer arrays, their mark pointers, and the two
      # sets of per-mark Array(BinaryValue) headers.
      grid_bytes = 2_i64 * instance_sizeof(Array(Array(BinaryValue))).to_i64
      grid_bytes += 2_i64 * marks * (
        sizeof(Pointer(Array(BinaryValue))).to_i64 + instance_sizeof(Array(BinaryValue)).to_i64
      )
      per_lane += grid_bytes

      # One detached UInt64 type/name and one reusable eight-byte encode
      # scratch are created per additional lane.
      descriptor_bytes = instance_sizeof(BinaryDataType).to_i64 +
                         instance_sizeof(String).to_i64 + "UInt64".bytesize.to_i64 +
                         sizeof(UInt64).to_i64
      additional_count * (per_lane + descriptor_bytes)
    end
  end
end
