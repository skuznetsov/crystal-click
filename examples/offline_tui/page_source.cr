require "../../src/crystal_click"

module CrystalClick
  module Examples
    struct OfflineEqualityFilter
      getter column : String
      getter value : UInt64 | String

      def initialize(column : String, value : UInt64 | String)
        @column = column.dup
        @value = value.is_a?(String) ? value.dup : value
      end
    end

    struct OfflinePage
      getter start_row : UInt64
      getter end_row : UInt64
      getter total_rows : UInt64
      getter column_names : Array(String)
      getter row_offsets : Array(UInt64)
      getter rows : Array(Array(String))

      def initialize(
        @start_row : UInt64,
        @end_row : UInt64,
        @total_rows : UInt64,
        @column_names : Array(String),
        @row_offsets : Array(UInt64),
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
          column_type = WidePart.catalog_type(column.type) ||
                        raise(UnsupportedFormatError.new("selected table column type is unsupported"))
          column_types << column_type.dup
        end

        @table = table
        @columns = columns.map(&.dup)
        @column_names = @columns.map(&.dup)
        @column_types = column_types
        @page_rows = page_rows
        @total_rows = checked_total_rows(table.resolved_scan_parts)
      end

      def load(start_row : UInt64, equality : OfflineEqualityFilter? = nil) : OfflinePage
        raise BoundsError.new("window start row is past the end of the table") if start_row > @total_rows

        remaining_rows = @total_rows - start_row
        expected_rows = {@page_rows.to_u64, remaining_rows}.min.to_i
        end_row = start_row + expected_rows.to_u64
        result_capacity = equality ? 0 : expected_rows
        rows = Array(Array(String)).new(result_capacity)
        row_offsets = Array(UInt64).new(result_capacity)
        observed_rows = 0_u64
        filter_column = equality.try(&.column)
        filter_value = equality.try(&.value)
        validate_equality_filter(filter_column, filter_value) if equality

        @table.scan_typed_window(@columns, start_row, @page_rows) do |batch|
          expected_offset = start_row + observed_rows
          unless batch.source_row_offset == expected_offset
            raise CorruptPartError.new("typed window batch is not contiguous with requested row offset")
          end

          batch_size = typed_column_size(batch, @columns[0], @column_types[0])
          raise CorruptPartError.new("typed window emitted an empty batch") if batch_size == 0
          @columns.each_with_index do |column, index|
            unless typed_column_size(batch, column, @column_types[index]) == batch_size
              raise CorruptPartError.new("typed window selected columns have different row counts")
            end
          end
          if observed_rows > expected_rows.to_u64 || batch_size.to_u64 > expected_rows.to_u64 - observed_rows
            raise CorruptPartError.new("typed window returned more rows than requested")
          end

          matched_indices = if column = filter_column
                              value = filter_value || raise(CorruptPartError.new("equality filter value disappeared"))
                              equality_match_indices(batch, column, value)
                            else
                              nil
                            end

          if indices = matched_indices
            indices.each do |matched_index|
              row_index = matched_index.to_i
              unless row_index >= 0 && row_index < batch_size
                raise CorruptPartError.new("equality filter matched a row outside the typed batch")
              end
              rows << format_row(batch, row_index)
              row_offsets << batch.source_row_offset + row_index.to_u64
            end
          else
            batch_size.times do |row_index|
              rows << format_row(batch, row_index)
              row_offsets << batch.source_row_offset + row_index.to_u64
            end
          end
          observed_rows += batch_size.to_u64
          nil
        end

        unless observed_rows == expected_rows.to_u64
          raise CorruptPartError.new("typed window returned fewer rows than expected")
        end

        OfflinePage.new(start_row, end_row, @total_rows, @column_names.dup, row_offsets, rows)
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

      private def validate_equality_filter(column : String?, value : (UInt64 | String)?) : Nil
        selected_column = column || raise(CorruptPartError.new("equality filter column disappeared"))
        selected_value = value || raise(CorruptPartError.new("equality filter value disappeared"))
        column_index = @columns.index(selected_column) ||
                       raise(UnsupportedFormatError.new("equality filter column must be selected"))

        case selected_value
        when UInt64
          unless @column_types[column_index] == "UInt64"
            raise UnsupportedFormatError.new("UInt64 equality filter requires an exact UInt64 column")
          end
        when String
          unless @column_types[column_index] == "String"
            raise UnsupportedFormatError.new("String equality filter requires an exact String column")
          end
        else
          raise UnsupportedFormatError.new("equality filter type is unsupported")
        end
      end

      private def equality_match_indices(batch : WidePartTableBatch, column : String, value : UInt64 | String) : Array(Int32)
        matches = Array(Int32).new
        case value
        when UInt64
          batch.values_for(column, UInt64).each_with_index do |candidate, index|
            matches << index.to_i32 if candidate == value
          end
        when String
          batch.strings_for(column).each_with_index do |candidate, index|
            matches << index.to_i32 if candidate == value
          end
        end
        matches
      end

      private def typed_column_size(batch : WidePartTableBatch, column : String, type : String) : Int32
        case type
        when "Bool"
          batch.bools_for(column).size
        when "UInt8"
          batch.values_for(column, UInt8).size
        when "UInt16"
          batch.values_for(column, UInt16).size
        when "Date"
          batch.date_codes_for(column).size
        when "UInt32"
          batch.values_for(column, UInt32).size
        when "DateTime"
          batch.datetime_seconds_for(column).size
        when "UInt64"
          batch.values_for(column, UInt64).size
        when "Int8"
          batch.values_for(column, Int8).size
        when "Int16"
          batch.values_for(column, Int16).size
        when "Int32"
          batch.values_for(column, Int32).size
        when "Date32"
          batch.date32_codes_for(column).size
        when "Int64"
          batch.values_for(column, Int64).size
        when "Float32"
          batch.values_for(column, Float32).size
        when "Float64"
          batch.values_for(column, Float64).size
        when "Nullable(Bool)"
          batch.nullable_bools_for(column).size
        when "IPv4"
          batch.ipv4s_for(column).size
        when "Nullable(IPv4)"
          batch.nullable_ipv4s_for(column).size
        when "IPv6"
          batch.ipv6s_for(column).size
        when "Nullable(IPv6)"
          batch.nullable_ipv6s_for(column).size
        when "UUID"
          batch.uuids_for(column).size
        when "Nullable(UUID)"
          batch.nullable_uuids_for(column).size
        when "String"
          batch.strings_for(column).size
        when "Nullable(UInt8)"
          batch.nullable_values_for(column, UInt8).size
        when "Nullable(UInt16)"
          batch.nullable_values_for(column, UInt16).size
        when "Nullable(Date)"
          batch.nullable_date_codes_for(column).size
        when "Nullable(UInt32)"
          batch.nullable_values_for(column, UInt32).size
        when "Nullable(DateTime)"
          batch.nullable_datetime_seconds_for(column).size
        when "Nullable(UInt64)"
          batch.nullable_values_for(column, UInt64).size
        when "Nullable(Int8)"
          batch.nullable_values_for(column, Int8).size
        when "Nullable(Int16)"
          batch.nullable_values_for(column, Int16).size
        when "Nullable(Int32)"
          batch.nullable_values_for(column, Int32).size
        when "Nullable(Date32)"
          batch.nullable_date32_codes_for(column).size
        when "Nullable(Int64)"
          batch.nullable_values_for(column, Int64).size
        when "Nullable(Float32)"
          batch.nullable_values_for(column, Float32).size
        when "Nullable(Float64)"
          batch.nullable_values_for(column, Float64).size
        when "Nullable(String)"
          batch.nullable_strings_for(column).size
        else
          if WidePart.datetime64_scale(type)
            batch.datetime64_ticks_for(column).size
          elsif WidePart.nullable_datetime64_scale(type)
            batch.nullable_datetime64_ticks_for(column).size
          elsif WidePart.fixed_string_width(type)
            batch.fixed_strings_for(column).size
          elsif WidePart.nullable_fixed_string_width(type)
            batch.nullable_fixed_strings_for(column).size
          elsif WidePart.enum8_codes(type)
            if type.starts_with?("Nullable(")
              batch.nullable_enum8_codes_for(column).size
            else
              batch.enum8_codes_for(column).size
            end
          elsif WidePart.enum16_codes(type)
            if type.starts_with?("Nullable(")
              batch.nullable_enum16_codes_for(column).size
            else
              batch.enum16_codes_for(column).size
            end
          elsif WidePart.decimal32_scale(type)
            batch.decimal32_raw_for(column).size
          elsif WidePart.nullable_decimal32_scale(type)
            batch.nullable_decimal32_raw_for(column).size
          elsif WidePart.decimal64_scale(type)
            batch.decimal64_raw_for(column).size
          elsif WidePart.nullable_decimal64_scale(type)
            batch.nullable_decimal64_raw_for(column).size
          elsif WidePart.decimal128_scale(type)
            batch.decimal128_raw_for(column).size
          elsif WidePart.nullable_decimal128_scale(type)
            batch.nullable_decimal128_raw_for(column).size
          elsif WidePart.decimal256_scale(type)
            batch.decimal256_raw_for(column).size
          elsif WidePart.nullable_decimal256_scale(type)
            batch.nullable_decimal256_raw_for(column).size
          else
            raise UnsupportedFormatError.new("selected table column type is unsupported")
          end
        end
      end

      private def format_row(batch : WidePartTableBatch, row_index : Int) : Array(String)
        row = Array(String).new(@columns.size)
        @columns.each_with_index do |column, index|
          row << format_cell(batch, column, @column_types[index], row_index)
        end
        row
      end

      private def format_cell(batch : WidePartTableBatch, column : String, type : String, row_index : Int) : String
        case type
        when "Bool"
          display_bool(batch.bools_for(column)[row_index])
        when "UInt8"
          batch.values_for(column, UInt8)[row_index].to_s
        when "UInt16"
          batch.values_for(column, UInt16)[row_index].to_s
        when "Date"
          batch.date_codes_for(column)[row_index].to_s
        when "UInt32"
          batch.values_for(column, UInt32)[row_index].to_s
        when "DateTime"
          batch.datetime_seconds_for(column)[row_index].to_s
        when "UInt64"
          batch.values_for(column, UInt64)[row_index].to_s
        when "Int8"
          batch.values_for(column, Int8)[row_index].to_s
        when "Int16"
          batch.values_for(column, Int16)[row_index].to_s
        when "Int32"
          batch.values_for(column, Int32)[row_index].to_s
        when "Date32"
          batch.date32_codes_for(column)[row_index].to_s
        when "Int64"
          batch.values_for(column, Int64)[row_index].to_s
        when "Float32"
          batch.values_for(column, Float32)[row_index].to_s
        when "Float64"
          batch.values_for(column, Float64)[row_index].to_s
        when "Nullable(Bool)"
          display_nullable_bool(batch.nullable_bools_for(column)[row_index])
        when "IPv4"
          batch.ipv4s_for(column)[row_index].to_s
        when "Nullable(IPv4)"
          batch.nullable_ipv4s_for(column)[row_index].try(&.to_s) || "NULL"
        when "IPv6"
          batch.ipv6s_for(column)[row_index].to_s
        when "Nullable(IPv6)"
          batch.nullable_ipv6s_for(column)[row_index].try(&.to_s) || "NULL"
        when "UUID"
          batch.uuids_for(column)[row_index].to_s
        when "Nullable(UUID)"
          batch.nullable_uuids_for(column)[row_index].try(&.to_s) || "NULL"
        when "String"
          display_string(batch.strings_for(column)[row_index])
        when "Nullable(UInt8)"
          nullable_numeric_cell(batch, column, UInt8, row_index)
        when "Nullable(UInt16)"
          nullable_numeric_cell(batch, column, UInt16, row_index)
        when "Nullable(Date)"
          batch.nullable_date_codes_for(column)[row_index].try(&.to_s) || "NULL"
        when "Nullable(UInt32)"
          nullable_numeric_cell(batch, column, UInt32, row_index)
        when "Nullable(DateTime)"
          batch.nullable_datetime_seconds_for(column)[row_index].try(&.to_s) || "NULL"
        when "Nullable(UInt64)"
          nullable_numeric_cell(batch, column, UInt64, row_index)
        when "Nullable(Int8)"
          nullable_numeric_cell(batch, column, Int8, row_index)
        when "Nullable(Int16)"
          nullable_numeric_cell(batch, column, Int16, row_index)
        when "Nullable(Int32)"
          nullable_numeric_cell(batch, column, Int32, row_index)
        when "Nullable(Date32)"
          batch.nullable_date32_codes_for(column)[row_index].try(&.to_s) || "NULL"
        when "Nullable(Int64)"
          nullable_numeric_cell(batch, column, Int64, row_index)
        when "Nullable(Float32)"
          nullable_numeric_cell(batch, column, Float32, row_index)
        when "Nullable(Float64)"
          nullable_numeric_cell(batch, column, Float64, row_index)
        when "Nullable(String)"
          value = batch.nullable_strings_for(column)[row_index]
          value ? display_string(value) : "NULL"
        else
          if scale = WidePart.datetime64_scale(type)
            "#{batch.datetime64_ticks_for(column)[row_index]} [p=#{scale}]"
          elsif scale = WidePart.nullable_datetime64_scale(type)
            value = batch.nullable_datetime64_ticks_for(column)[row_index]
            value ? "#{value} [p=#{scale}]" : "NULL"
          elsif WidePart.fixed_string_width(type)
            display_string(batch.fixed_strings_for(column)[row_index])
          elsif WidePart.nullable_fixed_string_width(type)
            value = batch.nullable_fixed_strings_for(column)[row_index]
            value ? display_string(value) : "NULL"
          elsif WidePart.enum8_codes(type)
            if type.starts_with?("Nullable(")
              value = batch.nullable_enum8_codes_for(column)[row_index]
              value ? value.to_s : "NULL"
            else
              batch.enum8_codes_for(column)[row_index].to_s
            end
          elsif WidePart.enum16_codes(type)
            if type.starts_with?("Nullable(")
              value = batch.nullable_enum16_codes_for(column)[row_index]
              value ? value.to_s : "NULL"
            else
              batch.enum16_codes_for(column)[row_index].to_s
            end
          elsif scale = WidePart.decimal32_scale(type)
            "#{batch.decimal32_raw_for(column)[row_index]} [s=#{scale}]"
          elsif scale = WidePart.nullable_decimal32_scale(type)
            value = batch.nullable_decimal32_raw_for(column)[row_index]
            value ? "#{value} [s=#{scale}]" : "NULL"
          elsif scale = WidePart.decimal64_scale(type)
            "#{batch.decimal64_raw_for(column)[row_index]} [s=#{scale}]"
          elsif scale = WidePart.nullable_decimal64_scale(type)
            value = batch.nullable_decimal64_raw_for(column)[row_index]
            value ? "#{value} [s=#{scale}]" : "NULL"
          elsif scale = WidePart.decimal128_scale(type)
            "#{batch.decimal128_raw_for(column)[row_index]} [s=#{scale}]"
          elsif scale = WidePart.nullable_decimal128_scale(type)
            value = batch.nullable_decimal128_raw_for(column)[row_index]
            value ? "#{value} [s=#{scale}]" : "NULL"
          elsif scale = WidePart.decimal256_scale(type)
            "#{batch.decimal256_raw_for(column)[row_index]} [s=#{scale}]"
          elsif scale = WidePart.nullable_decimal256_scale(type)
            value = batch.nullable_decimal256_raw_for(column)[row_index]
            value ? "#{value} [s=#{scale}]" : "NULL"
          else
            raise UnsupportedFormatError.new("selected table column type is unsupported")
          end
        end
      end

      private def nullable_numeric_cell(batch : WidePartTableBatch, column : String, type : T.class, row_index : Int) : String forall T
        value = batch.nullable_values_for(column, type)[row_index]
        value ? value.to_s : "NULL"
      end

      private def display_bool(value : Bool) : String
        value ? "true" : "false"
      end

      private def display_nullable_bool(value : Bool?) : String
        value.nil? ? "NULL" : display_bool(value)
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
