module CrystalClick
  # Opens and validates the hidden UInt64 sibling required to admit a Count
  # state reader into a table. The key remains identity/control metadata; its
  # values are never exposed through the Count batch API.
  class WideAggregateCountPairAdmission
    getter key_name : String
    getter key_reader : WidePart

    def self.open(
      path : String,
      count_reader : WidePart,
      checksums : PartChecksums,
      max_marks : Int,
      max_mark_rows : UInt64,
    ) : WideAggregateCountPairAdmission
      unless WideAggregateCountStoragePlan.for_type_name(count_reader.column_type)
        raise UnsupportedFormatError.new("selected column is not an admitted AggregateFunction(count) state")
      end

      key_name = count_reader.aggregate_count_key_column_name
      key_reader = WidePart.open_typed(path, key_name)
      unless key_reader.column_type == "UInt64"
        raise CorruptPartError.new("AggregateFunction(count) sibling is not an exact UInt64 column")
      end

      key_mark_rows = key_reader.mark_row_counts
      unless key_reader.row_count == count_reader.row_count && key_mark_rows == count_reader.mark_row_counts
        raise CorruptPartError.new("AggregateFunction(count) sibling row-mark axes differ")
      end
      raise BoundsError.new("AggregateFunction(count) sibling mark count exceeds per-reader limit") if key_mark_rows.size > max_marks
      key_mark_rows.each do |rows|
        raise BoundsError.new("AggregateFunction(count) sibling mark row count exceeds limit") if rows > max_mark_rows
      end

      key_reader.selected_checksum_names.each do |checksum_name|
        checksums.validate_selected_entries(path, checksum_name)
      end

      new(key_name, key_reader)
    end

    private def initialize(@key_name : String, @key_reader : WidePart)
    end
  end
end
