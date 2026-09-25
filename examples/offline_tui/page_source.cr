require "../../src/crystal_click"

module CrystalClick
  module Examples
    struct OfflinePage
      getter start_row : UInt64
      getter total_rows : UInt64
      getter column_names : Array(String)
      getter rows : Array(Array(String))

      def initialize(
        @start_row : UInt64,
        @total_rows : UInt64,
        @column_names : Array(String),
        @rows : Array(Array(String)),
      )
      end
    end

    # Bounded, owned display pages over an OfflineTable's resolved physical rows.
    class OfflinePageSource
      MAX_PAGE_ROWS           = 256
      MAX_PAGE_COLUMNS        = WidePartTable::MAX_COLUMNS
      MAX_STRING_SOURCE_BYTES = 256

      @table : OfflineTable
      @columns : Array(String)
      @column_names : Array(String)
      @column_types : Array(String)
      @page_rows : Int32
      @total_rows : UInt64

      def initialize(table : OfflineTable, columns : Array(String), page_rows : Int32)
        raise BoundsError.new("page row count is out of range") if page_rows <= 0 || page_rows > MAX_PAGE_ROWS
        raise BoundsError.new("no columns selected") if columns.empty?
        raise BoundsError.new("column count exceeds limit") if columns.size > MAX_PAGE_COLUMNS

        table_columns = table.columns
        selected = Set(String).new
        column_types = Array(String).new(columns.size)
        columns.each do |name|
          raise BoundsError.new("column name is empty or exceeds limit") if name.empty? || name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
          raise BoundsError.new("duplicate selected column") if selected.includes?(name)
          selected << name

          column = table_columns.find { |entry| entry.name == name } ||
                   raise(UnsupportedFormatError.new("selected column is not declared by table DDL"))
          raise UnsupportedFormatError.new("ALIAS columns cannot be materialized") if column.alias_column
          unless WidePart.supports_typed_type?(column.type)
            raise UnsupportedFormatError.new("selected table column type is unsupported")
          end
          column_types << column.type.dup
        end

        @table = table
        @columns = columns.map(&.dup)
        @column_names = @columns.map(&.dup)
        @column_types = column_types
        @page_rows = page_rows
        @total_rows = checked_total_rows(table.resolved_scan_parts)
      end

      def load(start_row : UInt64) : OfflinePage
        raise BoundsError.new("window start row is past the end of the table") if start_row > @total_rows

        remaining_rows = @total_rows - start_row
        expected_rows = {@page_rows.to_u64, remaining_rows}.min.to_i
        rows = Array(Array(String)).new(expected_rows)
        observed_rows = 0_u64

        @table.scan_typed_window(@columns, start_row, @page_rows) do |batch|
          expected_offset = start_row + observed_rows
          unless batch.source_row_offset == expected_offset
            raise CorruptPartError.new("typed window batch is not contiguous with requested row offset")
          end

          formatted_columns = Array(Array(String)).new(@columns.size)
          @columns.each_with_index do |column, index|
            formatted_columns << format_column(batch, column, @column_types[index])
          end

          batch_size = formatted_columns[0].size
          raise CorruptPartError.new("typed window emitted an empty batch") if batch_size == 0
          unless formatted_columns.all? { |values| values.size == batch_size }
            raise CorruptPartError.new("typed window selected columns have different row counts")
          end
          if observed_rows > expected_rows.to_u64 || batch_size.to_u64 > expected_rows.to_u64 - observed_rows
            raise CorruptPartError.new("typed window returned more rows than requested")
          end

          batch_size.times do |row_index|
            row = Array(String).new(@columns.size)
            formatted_columns.each { |values| row << values[row_index] }
            rows << row
          end
          observed_rows += batch_size.to_u64
          nil
        end

        unless observed_rows == expected_rows.to_u64
          raise CorruptPartError.new("typed window returned fewer rows than expected")
        end

        OfflinePage.new(start_row, @total_rows, @column_names.dup, rows)
      end

      private def checked_total_rows(parts : Array(OfflinePartCandidate)) : UInt64
        total = 0_u64
        parts.each do |part|
          if part.row_count > WidePartTable::MAX_TOTAL_ROWS ||
             total > WidePartTable::MAX_TOTAL_ROWS - part.row_count
            raise BoundsError.new("table candidate row count exceeds limit")
          end
          total += part.row_count
        end
        total
      end

      private def format_column(batch : WidePartTableBatch, column : String, type : String) : Array(String)
        case type
        when "UInt8"
          format_numeric_values(batch, column, UInt8)
        when "UInt16"
          format_numeric_values(batch, column, UInt16)
        when "UInt32"
          format_numeric_values(batch, column, UInt32)
        when "UInt64"
          format_numeric_values(batch, column, UInt64)
        when "Int8"
          format_numeric_values(batch, column, Int8)
        when "Int16"
          format_numeric_values(batch, column, Int16)
        when "Int32"
          format_numeric_values(batch, column, Int32)
        when "Int64"
          format_numeric_values(batch, column, Int64)
        when "Float32"
          format_numeric_values(batch, column, Float32)
        when "Float64"
          format_numeric_values(batch, column, Float64)
        when "String"
          batch.strings_for(column).map { |value| display_string(value) }.to_a
        when "Nullable(UInt8)"
          format_nullable_numeric_values(batch, column, UInt8)
        when "Nullable(UInt16)"
          format_nullable_numeric_values(batch, column, UInt16)
        when "Nullable(UInt32)"
          format_nullable_numeric_values(batch, column, UInt32)
        when "Nullable(UInt64)"
          format_nullable_numeric_values(batch, column, UInt64)
        when "Nullable(Int8)"
          format_nullable_numeric_values(batch, column, Int8)
        when "Nullable(Int16)"
          format_nullable_numeric_values(batch, column, Int16)
        when "Nullable(Int32)"
          format_nullable_numeric_values(batch, column, Int32)
        when "Nullable(Int64)"
          format_nullable_numeric_values(batch, column, Int64)
        when "Nullable(Float32)"
          format_nullable_numeric_values(batch, column, Float32)
        when "Nullable(Float64)"
          format_nullable_numeric_values(batch, column, Float64)
        when "Nullable(String)"
          batch.nullable_strings_for(column).map do |value|
            value ? display_string(value) : "NULL"
          end.to_a
        else
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
      end

      private def format_numeric_values(batch : WidePartTableBatch, column : String, type : T.class) : Array(String) forall T
        batch.values_for(column, type).map(&.to_s).to_a
      end

      private def format_nullable_numeric_values(batch : WidePartTableBatch, column : String, type : T.class) : Array(String) forall T
        batch.nullable_values_for(column, type).map do |value|
          value ? value.to_s : "NULL"
        end.to_a
      end

      private def display_string(value : String) : String
        byte_count = value.bytesize < MAX_STRING_SOURCE_BYTES ? value.bytesize : MAX_STRING_SOURCE_BYTES
        # String#inspect escapes non-printable and malformed UTF-8 bytes, including
        # a multibyte sequence cut by this raw-byte display limit.
        display = value.byte_slice(0, byte_count).inspect
        value.bytesize > MAX_STRING_SOURCE_BYTES ? "[truncated] #{display}" : display
      end
    end
  end
end
