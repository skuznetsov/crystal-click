module CrystalClick
  # Opens and validates the hidden UInt64 sibling required to admit a Count
  # state reader into a table. The key remains identity/control metadata; its
  # values are never exposed through the Count batch API.
  class WideAggregateCountPairAdmission
    @key_names : Array(String)
    getter key_reader : WidePart

    def key_name : String
      String.new(@key_names.first.to_slice)
    end

    def key_names : Array(String)
      @key_names.map { |name| String.new(name.to_slice) }
    end

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

      key_names = count_reader.aggregate_count_key_column_names
      unless (key_names.size == 1 || key_names.size == 2) && key_names.to_set.size == key_names.size
        raise CorruptPartError.new("AggregateFunction(count) sibling roster is not one or two distinct UInt64 keys")
      end

      key_reader = nil.as(WidePart?)
      key_names.each do |key_name|
        reader = WidePart.open_typed(path, key_name)
        unless reader.column_type == "UInt64"
          raise CorruptPartError.new("AggregateFunction(count) sibling is not an exact UInt64 column")
        end

        key_mark_rows = reader.mark_row_counts
        unless reader.row_count == count_reader.row_count && key_mark_rows == count_reader.mark_row_counts
          raise CorruptPartError.new("AggregateFunction(count) sibling row-mark axes differ")
        end
        raise BoundsError.new("AggregateFunction(count) sibling mark count exceeds per-reader limit") if key_mark_rows.size > max_marks
        key_mark_rows.each do |rows|
          raise BoundsError.new("AggregateFunction(count) sibling mark row count exceeds limit") if rows > max_mark_rows
        end

        reader.selected_checksum_names.each do |checksum_name|
          checksums.validate_selected_entries(path, checksum_name)
        end
        key_reader ||= reader
      end

      new(key_names, key_reader.not_nil!)
    end

    private def initialize(@key_names : Array(String), @key_reader : WidePart)
    end
  end
end
