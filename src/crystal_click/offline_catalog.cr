module CrystalClick
  alias OfflineColumnValue = UInt8 | UInt16 | UInt32 | UInt64 |
                             Int8 | Int16 | Int32 | Int64 | Int128 |
                             Float32 | Float64 | Bool | String | UUIDValue | IPv4Value | IPv6Value | Decimal256Value |
                             Array(UInt64) | Array(String) | Nil

  # The column name and declared type parsed from ClickHouse table DDL.
  struct OfflineColumn
    getter name : String
    getter type : String
    getter alias_column : Bool
    getter key_candidate_column : Bool

    def initialize(
      @name : String,
      @type : String,
      @alias_column : Bool = false,
      @key_candidate_column : Bool = true,
    )
    end
  end

  # A physical on-disk part directory. This identity does not imply that the
  # ClickHouse server considers the part active or otherwise authoritative.
  struct OfflinePartCandidate
    getter name : String
    getter path : String
    getter info : MergeTreePartInfo
    getter row_count : UInt64

    def initialize(@name : String, @path : String, @info : MergeTreePartInfo, @row_count : UInt64)
    end
  end

  # Read-only view of one table's parsed DDL and physical part candidates.
  class OfflineTable
    MAX_MATERIALIZED_VALUES_ROWS           = 100_000_u64
    MAX_MATERIALIZED_VALUES_STRING_BYTES   = 64_u64 * 1024 * 1024
    MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS = 1_000_000_u64

    getter name : String
    getter engine : String
    getter primary_key_column : String?

    @columns : Array(OfflineColumn)
    @part_candidates : Array(OfflinePartCandidate)?
    @uuid : String?
    @part_candidates_catalog : OfflineCatalog?

    def initialize(
      @name : String,
      @uuid : String?,
      @engine : String,
      @columns : Array(OfflineColumn),
      @part_candidates : Array(OfflinePartCandidate)?,
      @primary_key_column : String? = nil,
      @part_candidates_catalog : OfflineCatalog? = nil,
    )
    end

    def uuid : String
      raise UnsupportedFormatError.new("synthetic system table has no UUID") if @part_candidates_catalog
      value = @uuid || raise(UnsupportedFormatError.new("synthetic system table has no UUID"))
      value.dup
    end

    def columns : Array(OfflineColumn)
      @columns.dup
    end

    def [](column_name : String) : OfflineColumnSelection
      raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
      resolve_typed_ddl_selection(column_name, allow_unsupported_exact: true)
      OfflineColumnSelection.new(self, column_name)
    end

    def materialize_selected_values(
      column_name : String,
      max_rows : UInt64 = MAX_MATERIALIZED_VALUES_ROWS,
      max_string_bytes : UInt64 = MAX_MATERIALIZED_VALUES_STRING_BYTES,
    ) : Array(OfflineColumnValue)
      raise BoundsError.new("selected column row limit exceeds hard limit") if max_rows > MAX_MATERIALIZED_VALUES_ROWS
      raise BoundsError.new("selected column String payload limit exceeds hard limit") if max_string_bytes > MAX_MATERIALIZED_VALUES_STRING_BYTES

      if catalog = @part_candidates_catalog
        return catalog.part_candidates_values(column_name, max_rows, max_string_bytes)
      end

      source_name, _source_type, selected_type, _json_path = resolve_typed_ddl_selection(column_name)
      source_column = @columns.find { |entry| entry.name == source_name } || raise(CorruptPartError.new("selected column disappeared from table DDL"))
      raise UnsupportedFormatError.new("ALIAS columns cannot be materialized") if source_column.alias_column

      expected_rows = 0_u64
      candidates = resolved_scan_parts
      candidates.each do |candidate|
        if expected_rows > max_rows || candidate.row_count > max_rows - expected_rows
          raise BoundsError.new("selected column materialization exceeds row limit")
        end
        expected_rows += candidate.row_count
      end

      values = Array(OfflineColumnValue).new(expected_rows.to_i)
      observed_rows = 0_u64
      string_bytes = 0_u64
      array_elements = [0_u64]

      unless candidates.empty?
        scan_typed([column_name]) do |batch|
          observed_rows, string_bytes = append_materialized_value_batch(
            values,
            batch,
            column_name,
            selected_type,
            observed_rows,
            string_bytes,
            array_elements,
            expected_rows,
            max_string_bytes
          )
          nil
        end
      end

      raise CorruptPartError.new("observed selected column row count differs from preflight count") unless observed_rows == expected_rows
      values
    end

    private def append_materialized_value_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      selected_type : String,
      observed_rows : UInt64,
      string_bytes : UInt64,
      array_elements : Array(UInt64),
      expected_rows : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      if WidePart.supports_ipv4_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.ipv4s_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif WidePart.supports_nullable_ipv4_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.nullable_ipv4s_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif WidePart.supports_ipv6_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.ipv6s_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif WidePart.supports_nullable_ipv6_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.nullable_ipv6s_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif WidePart.supports_uuid_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.uuids_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif WidePart.supports_nullable_uuid_type?(selected_type)
        observed_rows = append_materialized_values(values, batch.nullable_uuids_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Bool"
        observed_rows = append_materialized_values(values, batch.bools_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.enum8_codes(selected_type).nil? && !selected_type.starts_with?("Nullable(")
        observed_rows = append_materialized_values(values, batch.enum8_codes_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.enum16_codes(selected_type).nil? && !selected_type.starts_with?("Nullable(")
        observed_rows = append_materialized_values(values, batch.enum16_codes_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.decimal32_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.decimal32_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.decimal64_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.decimal64_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.decimal128_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.decimal128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.decimal256_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.decimal256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Nullable(Bool)"
        observed_rows = append_materialized_values(values, batch.nullable_bools_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type.starts_with?("Nullable(") && !WidePart.enum8_codes(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_enum8_codes_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type.starts_with?("Nullable(") && !WidePart.enum16_codes(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_enum16_codes_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal32_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal32_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal64_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal64_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal128_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal256_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      end

      case selected_type
      when "Date"
        observed_rows = append_date_codes_values(values, batch, column_name, observed_rows, expected_rows)
      when "UInt8"
        observed_rows = append_uint8_values(values, batch, column_name, observed_rows, expected_rows)
      when "UInt16"
        observed_rows = append_uint16_values(values, batch, column_name, observed_rows, expected_rows)
      when "UInt32"
        observed_rows = append_uint32_values(values, batch, column_name, observed_rows, expected_rows)
      when "UInt64"
        observed_rows = append_uint64_values(values, batch, column_name, observed_rows, expected_rows)
      when "Int8"
        observed_rows = append_int8_values(values, batch, column_name, observed_rows, expected_rows)
      when "Int16"
        observed_rows = append_int16_values(values, batch, column_name, observed_rows, expected_rows)
      when "Int32"
        observed_rows = append_int32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Date32"
        observed_rows = append_date32_codes_values(values, batch, column_name, observed_rows, expected_rows)
      when "DateTime"
        observed_rows = append_datetime_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when "Int64"
        observed_rows = append_int64_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("DateTime64(")
        unless WidePart.datetime64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_datetime64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
      when "Float32"
        observed_rows = append_float32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Float64"
        observed_rows = append_float64_values(values, batch, column_name, observed_rows, expected_rows)
      when "Array(UInt64)"
        selected_values = batch.array_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_uint64s(values, selected_values, array_elements[0])
      when "Array(String)"
        selected_values = batch.array_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "String"
        selected_values = batch.strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        string_bytes = append_materialized_strings(values, selected_values, string_bytes, max_string_bytes)
      when .starts_with?("FixedString(")
        unless WidePart.fixed_string_width(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        selected_values = batch.fixed_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        string_bytes = append_materialized_strings(values, selected_values, string_bytes, max_string_bytes)
      when .starts_with?("Nullable(FixedString(")
        unless WidePart.nullable_fixed_string_width(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        selected_values = batch.nullable_fixed_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        selected_values.each do |value|
          if string_value = value
            string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
            values << String.new(string_value.to_slice)
          else
            values << nil
          end
        end
      when "Nullable(String)"
        selected_values = batch.nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        selected_values.each do |value|
          if string_value = value
            string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
            values << String.new(string_value.to_slice)
          else
            values << nil
          end
        end
      when "Nullable(Date)"
        observed_rows = append_nullable_date_codes_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Date32)"
        observed_rows = append_nullable_date32_codes_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(DateTime)"
        observed_rows = append_nullable_datetime_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("Nullable(DateTime64(")
        unless WidePart.nullable_datetime64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_nullable_datetime64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(UInt8)"
        observed_rows = append_nullable_uint8_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(UInt16)"
        observed_rows = append_nullable_uint16_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(UInt32)"
        observed_rows = append_nullable_uint32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(UInt64)"
        observed_rows = append_nullable_uint64_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Int8)"
        observed_rows = append_nullable_int8_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Int16)"
        observed_rows = append_nullable_int16_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Int32)"
        observed_rows = append_nullable_int32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Int64)"
        observed_rows = append_nullable_int64_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Float32)"
        observed_rows = append_nullable_float32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Float64)"
        observed_rows = append_nullable_float64_values(values, batch, column_name, observed_rows, expected_rows)
      else
        raise UnsupportedFormatError.new("selected table column type is unsupported")
      end
      {observed_rows, string_bytes}
    end

    def part_candidates : Array(OfflinePartCandidate)
      candidates = @part_candidates
      raise UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only") unless candidates
      candidates.dup
    end

    # Resolve the physical inventory to a deterministic, unambiguous set of
    # maximal covering parts for an offline scan. This is an inferred scan
    # set, not ClickHouse server Active state.
    def resolved_scan_parts : Array(OfflinePartCandidate)
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      candidates = @part_candidates || raise(UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only"))
      reject_transaction_metadata!(candidates)
      return [] of OfflinePartCandidate if candidates.empty?

      covered = Array(Bool).new(candidates.size, false)
      candidates.each_with_index do |left, left_index|
        right_index = left_index + 1
        while right_index < candidates.size
          right = candidates[right_index]
          left_info = left.info
          right_info = right.info

          if same_part_info?(left_info, right_info)
            raise InvalidPartError.new("duplicate MergeTree part identity: #{left.name} and #{right.name}")
          end

          if left_info.overlaps?(right_info)
            left_contains = merge_tree_part_contains?(left_info, right_info)
            right_contains = merge_tree_part_contains?(right_info, left_info)
            if left_contains && right_contains
              raise InvalidPartError.new("duplicate MergeTree part identity: #{left.name} and #{right.name}")
            elsif left_contains
              covered[right_index] = true
            elsif right_contains
              covered[left_index] = true
            else
              raise InvalidPartError.new("part candidates overlap without a covering relation: #{left.name} and #{right.name}")
            end
          end

          right_index += 1
        end
      end

      resolved = Array(OfflinePartCandidate).new(candidates.size)
      candidates.each_with_index do |candidate, index|
        resolved << candidate unless covered[index]
      end
      reject_unsupported_scan_features!(resolved)
      resolved
    end

    # Scan table-declared UInt64 columns through the existing Wide-part reader.
    # The callback receives borrowed slices valid only until it returns.
    def scan_uint64(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        column = @columns.find { |entry| entry.name == column_name }
        raise UnsupportedFormatError.new("selected column is not declared by table DDL") unless column
        raise UnsupportedFormatError.new("selected table column is not UInt64") unless column.type == "UInt64"
      end

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      paths = candidates.map(&.path)
      reader = WidePartTable.open_selected(paths, columns)
      reader.scan(batch_rows: batch_rows, &block)
    end

    # Select candidate granules for an inclusive range on one simple
    # ascending UInt64 ORDER BY key. The callback receives whole granules;
    # callers must apply the exact key predicate to each returned batch.
    def scan_uint64_pk_candidates(
      columns : Array(String),
      lower_bound : UInt64? = nil,
      upper_bound : UInt64? = nil,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("at least one primary-key bound is required") unless lower_bound || upper_bound
      if lower = lower_bound
        if upper = upper_bound
          raise BoundsError.new("primary-key lower bound exceeds upper bound") if lower > upper
        end
      end
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        column = @columns.find { |entry| entry.name == column_name }
        raise UnsupportedFormatError.new("selected column is not declared by table DDL") unless column
        raise UnsupportedFormatError.new("selected table column is not UInt64") unless column.type == "UInt64"
      end

      key_column = @primary_key_column || raise(UnsupportedFormatError.new("table does not have a supported simple ascending UInt64 ORDER BY key"))
      raise UnsupportedFormatError.new("selected columns must include the ORDER BY key") unless selected.includes?(key_column)

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      reader = WidePartTable.open_selected(candidates.map(&.path), columns)
      reader.column_types.each do |column_name, part_type|
        ddl_column = @columns.find { |entry| entry.name == column_name } || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        unless ddl_column.type == part_type
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end

      part_mark_rows = reader.part_mark_row_counts
      raise CorruptPartError.new("selected part mark inventory changed") unless part_mark_rows.size == candidates.size
      candidate_marks = Array(Array(Int32)).new(candidates.size)
      candidates.each_with_index do |candidate, part_index|
        checksums = PartChecksums.open(candidate.path)
        index = PrimaryKeyIndex.open(candidate.path, part_mark_rows[part_index].size, checksums)
        candidate_marks << index.candidate_marks(lower_bound, upper_bound)
      end
      reader.scan_candidate_marks(candidate_marks, &block)
    end

    # Scan selected exact primitive numeric columns. The type declared by the
    # table DDL must exactly match each selected part's columns.txt type.
    def scan_numeric(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        column = @columns.find { |entry| entry.name == column_name }
        raise UnsupportedFormatError.new("selected column is not declared by table DDL") unless column
        raise UnsupportedFormatError.new("selected table column is not an exact primitive numeric type") unless WidePart.supports_numeric_type?(column.type)
      end

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      reader = WidePartTable.open_selected_numeric(candidates.map(&.path), columns)
      reader.column_types.each do |column_name, part_type|
        ddl_column = @columns.find { |entry| entry.name == column_name } || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        unless ddl_column.type == part_type
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader.scan_numeric(batch_rows: batch_rows, &block)
    end

    # Scan exact String, raw date/time codes, primitive numeric, and supported
    # Nullable columns. Selected part types must exactly match this table's DDL
    # before the first callback is allowed to run.
    def scan_typed(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      if reader = open_typed_reader(columns, batch_rows, "batch")
        reader.scan_typed(batch_rows: batch_rows, &block)
      end
    end

    # Read a bounded physical-row window from a MergeTree table. Batches borrow
    # their column buffers only for the duration of each callback.
    def scan_typed_window(
      columns : Array(String),
      start_row : UInt64,
      max_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      if reader = open_typed_reader(columns, max_rows, "window")
        reader.scan_typed_window(start_row, max_rows, &block)
      elsif start_row > 0
        raise BoundsError.new("window start row is past the end of the table")
      end
    end

    private def open_typed_reader(columns : Array(String), row_limit : Int, row_limit_label : String) : WidePartTable?
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("#{row_limit_label} row count is out of range") if row_limit <= 0 || row_limit > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      expected_sources = Hash(String, {String, String, String, Bool}).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        source_name, source_type, selected_type, json_path = resolve_typed_ddl_selection(column_name)
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.supports_typed_type?(selected_type)
        expected_sources[column_name] = {source_name, source_type, selected_type, json_path}
      end

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      reader = WidePartTable.open_selected_typed(candidates.map(&.path), columns)
      reader.column_sources.each do |column_name, part_source_name, part_source_type|
        ddl_source = expected_sources[column_name]? || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        if ddl_source[3]
          unless part_source_name == ddl_source[0] && part_source_type == ddl_source[1]
            raise UnsupportedFormatError.new("table DDL and selected JSON schema differ")
          end
        elsif part_source_name != ddl_source[0] || part_source_type != (WidePart.catalog_type(ddl_source[1]) || ddl_source[1])
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader.column_types.each do |column_name, part_type|
        ddl_source = expected_sources[column_name]? || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        unless ddl_source[2] == part_type
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader
    end

    private def checked_materialized_value_rows(observed : UInt64, batch_rows : UInt64, expected : UInt64) : UInt64
      if observed > expected || batch_rows > expected - observed
        raise CorruptPartError.new("observed selected column row count exceeds preflight count")
      end
      observed + batch_rows
    end

    private def append_uint8_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, UInt8), observed_rows, expected_rows)
    end

    private def append_uint16_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, UInt16), observed_rows, expected_rows)
    end

    private def append_date_codes_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.date_codes_for(column_name), observed_rows, expected_rows)
    end

    private def append_uint32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, UInt32), observed_rows, expected_rows)
    end

    private def append_uint64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, UInt64), observed_rows, expected_rows)
    end

    private def append_int8_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Int8), observed_rows, expected_rows)
    end

    private def append_int16_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Int16), observed_rows, expected_rows)
    end

    private def append_int32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Int32), observed_rows, expected_rows)
    end

    private def append_date32_codes_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.date32_codes_for(column_name), observed_rows, expected_rows)
    end

    private def append_datetime_seconds_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.datetime_seconds_for(column_name), observed_rows, expected_rows)
    end

    private def append_datetime64_ticks_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.datetime64_ticks_for(column_name), observed_rows, expected_rows)
    end

    private def append_int64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Int64), observed_rows, expected_rows)
    end

    private def append_float32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Float32), observed_rows, expected_rows)
    end

    private def append_float64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.values_for(column_name, Float64), observed_rows, expected_rows)
    end

    private def append_nullable_uint8_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, UInt8), observed_rows, expected_rows)
    end

    private def append_nullable_date_codes_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_date_codes_for(column_name), observed_rows, expected_rows)
    end

    private def append_nullable_date32_codes_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_date32_codes_for(column_name), observed_rows, expected_rows)
    end

    private def append_nullable_datetime_seconds_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_datetime_seconds_for(column_name), observed_rows, expected_rows)
    end

    private def append_nullable_datetime64_ticks_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_datetime64_ticks_for(column_name), observed_rows, expected_rows)
    end

    private def append_nullable_uint16_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, UInt16), observed_rows, expected_rows)
    end

    private def append_nullable_uint32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, UInt32), observed_rows, expected_rows)
    end

    private def append_nullable_uint64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, UInt64), observed_rows, expected_rows)
    end

    private def append_nullable_int8_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Int8), observed_rows, expected_rows)
    end

    private def append_nullable_int16_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Int16), observed_rows, expected_rows)
    end

    private def append_nullable_int32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Int32), observed_rows, expected_rows)
    end

    private def append_nullable_int64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Int64), observed_rows, expected_rows)
    end

    private def append_nullable_float32_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Float32), observed_rows, expected_rows)
    end

    private def append_nullable_float64_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_values_for(column_name, Float64), observed_rows, expected_rows)
    end

    private def append_materialized_values(values : Array(OfflineColumnValue), selected_values : Slice(T), observed_rows : UInt64, expected_rows : UInt64) : UInt64 forall T
      checked_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      selected_values.each { |value| values << value }
      checked_rows
    end

    private def append_materialized_strings(values : Array(OfflineColumnValue), selected_values : Slice(String), observed_bytes : UInt64, limit : UInt64) : UInt64
      selected_values.each do |value|
        observed_bytes = checked_materialized_value_string_bytes(observed_bytes, value.bytesize.to_u64, limit)
        values << String.new(value.to_slice)
      end
      observed_bytes
    end

    private def append_materialized_array_uint64s(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(UInt64)),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each { |row| values << row.dup }
      next_elements
    end

    private def append_materialized_array_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(String)),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(String).new(row.size)
        row.each { |value| owned_row << String.new(value.to_slice) }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def checked_materialized_value_array_elements(observed : UInt64, batch_elements : UInt64) : UInt64
      limit = MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS
      if observed > limit || batch_elements > limit - observed
        raise BoundsError.new("selected column materialization exceeds flattened Array element limit")
      end
      observed + batch_elements
    end

    private def checked_materialized_value_string_bytes(observed : UInt64, batch_bytes : UInt64, limit : UInt64) : UInt64
      if observed > limit || batch_bytes > limit - observed
        raise BoundsError.new("selected column materialization exceeds String payload limit")
      end
      observed + batch_bytes
    end

    private def resolve_typed_ddl_selection(column_name : String, allow_unsupported_exact : Bool = false) : {String, String, String, Bool}
      exact = @columns.find { |entry| entry.name == column_name }
      virtual = Array({String, String, String}).new
      @columns.each do |source|
        next unless WidePart.json_type?(source.type)
        prefix = "#{source.name}."
        next unless column_name.starts_with?(prefix)
        path = column_name.byte_slice(prefix.bytesize, column_name.bytesize - prefix.bytesize)
        if path_type = WidePart.json_typed_path_type(source.type, path)
          virtual << {source.name, source.type, path_type}
        end
      end

      if exact && !virtual.empty?
        raise UnsupportedFormatError.new("selected column is ambiguous between a literal dotted column and a JSON typed path")
      end
      if selected = exact
        unless allow_unsupported_exact || WidePart.supports_typed_type?(selected.type) || WidePart.catalog_type(selected.type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        selected_type = WidePart.catalog_type(selected.type) || selected.type
        return {selected.name, selected.type, selected_type, false}
      end
      raise UnsupportedFormatError.new("selected column is not declared by table DDL") if virtual.empty?
      raise UnsupportedFormatError.new("selected JSON typed path is ambiguous") unless virtual.size == 1
      {virtual[0][0], virtual[0][1], virtual[0][2], true}
    end

    private def same_part_info?(left : MergeTreePartInfo, right : MergeTreePartInfo) : Bool
      left.partition_id == right.partition_id &&
        left.min_block == right.min_block &&
        left.max_block == right.max_block &&
        left.level == right.level &&
        left.mutation == right.mutation
    end

    # Mirrors the pinned ClickHouse MergeTreePartInfo::contains relation.
    private def merge_tree_part_contains?(outer : MergeTreePartInfo, inner : MergeTreePartInfo) : Bool
      equal_block_range = outer.min_block == inner.min_block && outer.max_block == inner.max_block
      strictly_contains_block_range = equal_block_range ||
                                      outer.level > inner.level ||
                                      outer.level == MergeTreePartInfo::MAX_LEVEL ||
                                      outer.level == MergeTreePartInfo::LEGACY_MAX_LEVEL

      outer.partition_id == inner.partition_id &&
        outer.min_block <= inner.min_block &&
        outer.max_block >= inner.max_block &&
        outer.level >= inner.level &&
        outer.mutation >= inner.mutation &&
        strictly_contains_block_range
    end

    private def reject_transaction_metadata!(candidates : Array(OfflinePartCandidate)) : Nil
      candidates.each do |candidate|
        each_part_entry(candidate) do |entry|
          if entry == "txn_version.txt" || entry == "txn_version.txt.tmp"
            raise UnsupportedFormatError.new("transactional part metadata is not supported: #{candidate.name}")
          end
        end
      end
    end

    private def reject_unsupported_scan_features!(candidates : Array(OfflinePartCandidate)) : Nil
      candidates.each do |candidate|
        each_part_entry(candidate) do |entry|
          if entry.starts_with?("delete_bitmap_") && entry.ends_with?(".rbm") && entry.bytesize > "delete_bitmap_.rbm".bytesize
            raise UnsupportedFormatError.new("delete bitmap sidecars are not supported: #{candidate.name}")
          end
        end
        if part_has_row_exists_column?(candidate)
          raise UnsupportedFormatError.new("lightweight-delete _row_exists columns are not supported: #{candidate.name}")
        end
      end
    end

    private def each_part_entry(candidate : OfflinePartCandidate, &block : String -> Nil) : Nil
      entry_count = 0
      Dir.each_child(candidate.path) do |entry|
        entry_count += 1
        raise BoundsError.new("physical part entry count exceeds limit") if entry_count > PartChecksums::MAX_ENTRIES + 16
        yield entry
      end
    rescue ex : File::Error
      raise InvalidPartError.new("cannot inspect physical part directory: #{candidate.name}")
    end

    private def part_has_row_exists_column?(candidate : OfflinePartCandidate) : Bool
      path = File.join(candidate.path, "columns.txt")
      info = File.info?(path, follow_symlinks: false) || raise(UnsupportedFormatError.new("selected part columns.txt is missing or inaccessible: #{candidate.name}"))
      raise UnsupportedFormatError.new("selected part columns.txt is a symbolic link: #{candidate.name}") if info.type.symlink?
      raise UnsupportedFormatError.new("selected part columns.txt is not a regular file: #{candidate.name}") unless info.type.file?
      raise BoundsError.new("selected part columns.txt exceeds metadata limit") if info.size > WidePart::MAX_METADATA_FILE_BYTES

      text = String.build do |output|
        File.open(path, "r") do |input|
          buffer = Bytes.new(8_192)
          total = 0
          while (read = input.read(buffer)) > 0
            raise BoundsError.new("selected part columns.txt exceeds metadata limit") if read > WidePart::MAX_METADATA_FILE_BYTES - total
            output.write(buffer[0, read])
            total += read
          end
        end
      end
      bytes = text.to_slice
      unless text.bytesize.to_i64 == info.size && !bytes.empty? && bytes[bytes.size - 1] == 10
        raise CorruptPartError.new("selected part columns.txt is truncated or missing LF")
      end

      cursor = 0
      header, cursor = part_metadata_line(bytes, cursor)
      raise UnsupportedFormatError.new("invalid selected part columns.txt header") unless header == "columns format version: 1"
      count_line, cursor = part_metadata_line(bytes, cursor)
      match = /\A([0-9]+) columns:\z/.match(count_line) || raise(UnsupportedFormatError.new("invalid selected part column count"))
      column_count = match[1].to_i? || raise(UnsupportedFormatError.new("invalid selected part column count"))
      raise BoundsError.new("selected part column count exceeds limit") if column_count > WidePart::MAX_METADATA_COLUMNS
      raise UnsupportedFormatError.new("selected part columns.txt contains no columns") if column_count == 0

      column_count.times do
        line, cursor = part_metadata_line(bytes, cursor)
        return true if part_column_name(line) == "_row_exists"
      end

      raise UnsupportedFormatError.new("trailing selected part columns.txt data") unless cursor == bytes.size
      false
    rescue ex : File::Error
      raise UnsupportedFormatError.new("selected part columns.txt is inaccessible: #{candidate.name}")
    end

    private def part_metadata_line(bytes : Bytes, cursor : Int32) : {String, Int32}
      raise UnsupportedFormatError.new("truncated selected part columns.txt") if cursor < 0 || cursor >= bytes.size
      ending = cursor
      while ending < bytes.size && bytes[ending] != 10
        ending += 1
      end
      raise UnsupportedFormatError.new("truncated selected part columns.txt") if ending >= bytes.size
      raise BoundsError.new("selected part columns.txt line exceeds metadata limit") if ending - cursor + 1 > WidePart::MAX_METADATA_LINE_BYTES
      {String.new(bytes[cursor, ending - cursor]), ending + 1}
    end

    private def part_column_name(line : String) : String
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid selected part column identifier") if bytes.empty? || bytes[0] != '`'.ord
      end_index = -1
      decoded_length = 0
      decoded = String.build do |io|
        index = 1
        while index < bytes.size
          byte = bytes[index]
          if byte == '`'.ord
            if index + 1 < bytes.size && bytes[index + 1] == '`'.ord
              io.write_byte('`'.ord.to_u8)
              decoded_length += 1
              index += 2
              next
            end
            end_index = index + 1
            break
          elsif byte == '\\'.ord
            index += 1
            raise UnsupportedFormatError.new("invalid selected part column identifier escape") if index >= bytes.size
            escaped = bytes[index]
            if escaped == 'x'.ord
              raise UnsupportedFormatError.new("invalid selected part column identifier escape") if index + 2 >= bytes.size
              high = part_hex_digit(bytes[index + 1])
              low = part_hex_digit(bytes[index + 2])
              raise UnsupportedFormatError.new("invalid selected part column identifier escape") unless high && low
              io.write_byte((high.not_nil! << 4) | low.not_nil!)
              decoded_length += 1
              index += 3
              next
            elsif escaped == 'N'.ord
              index += 1
              next
            end
            decoded_byte = case escaped
                           when 'a'.ord then 0x07_u8
                           when 'b'.ord then 0x08_u8
                           when 'e'.ord then 0x1b_u8
                           when 'f'.ord then 0x0c_u8
                           when 'n'.ord then 0x0a_u8
                           when 'r'.ord then 0x0d_u8
                           when 't'.ord then 0x09_u8
                           when 'v'.ord then 0x0b_u8
                           when '0'.ord then 0_u8
                           else              escaped
                           end
            if decoded_byte != '\\'.ord && decoded_byte != '\''.ord && decoded_byte != '"'.ord && decoded_byte != '`'.ord && decoded_byte != '/'.ord && decoded_byte != '='.ord && decoded_byte >= 0x20
              io.write_byte('\\'.ord.to_u8)
              decoded_length += 1
            end
            io.write_byte(decoded_byte)
            decoded_length += 1
            index += 1
          else
            raise UnsupportedFormatError.new("invalid selected part column identifier") if byte == 0 || byte == 10 || byte == 13
            io.write_byte(byte)
            decoded_length += 1
            index += 1
          end
        end
      end
      raise UnsupportedFormatError.new("unterminated selected part column identifier") if end_index < 0
      raise UnsupportedFormatError.new("empty selected part column identifier") if decoded_length == 0
      raise UnsupportedFormatError.new("invalid selected part column type") if end_index >= bytes.size || bytes[end_index] != ' '.ord || end_index + 1 >= bytes.size
      raise UnsupportedFormatError.new("invalid selected part column type") if bytes[end_index + 1, bytes.size - end_index - 1].any? { |byte| byte == 0 || byte == 13 }
      decoded
    end

    private def part_hex_digit(byte : UInt8) : UInt8?
      if byte >= '0'.ord && byte <= '9'.ord
        byte - '0'.ord
      elsif byte >= 'a'.ord && byte <= 'f'.ord
        byte - 'a'.ord + 10
      elsif byte >= 'A'.ord && byte <= 'F'.ord
        byte - 'A'.ord + 10
      end
    end
  end

  # A selected offline column. Selection is metadata-only; values owns and
  # materializes the complete bounded projection when explicitly requested.
  class OfflineColumnSelection
    getter name : String

    @table : OfflineTable

    def initialize(@table : OfflineTable, name : String)
      @name = name.dup
    end

    def values(
      max_rows : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ROWS,
      max_string_bytes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
    ) : Array(OfflineColumnValue)
      @table.materialize_selected_values(@name, max_rows, max_string_bytes)
    end
  end

  # Read-only view of one database in an offline Atomic metadata tree.
  # The catalog reference preserves the lookup context after its original
  # caller drops the catalog variable; the UUID guards against metadata drift.
  class OfflineDatabase
    @catalog : OfflineCatalog
    @name : String
    @uuid : String?
    @virtual_system : Bool

    def initialize(@catalog : OfflineCatalog, name : String, uuid : String?, @virtual_system : Bool = false)
      @name = name.dup
      @uuid = uuid.try(&.dup)
    end

    def name : String
      @name.dup
    end

    def uuid : String
      raise UnsupportedFormatError.new("synthetic system database has no UUID") if @virtual_system
      value = @uuid || raise(UnsupportedFormatError.new("synthetic system database has no UUID"))
      value.dup
    end

    def virtual_system? : Bool
      @virtual_system
    end

    def owned_by?(catalog : OfflineCatalog) : Bool
      @catalog.same?(catalog)
    end

    def table_names : Array(String)
      @catalog.table_names(self)
    end

    def table(name : String) : OfflineTable
      @catalog.table(self, name)
    end

    def [](name : String) : OfflineTable
      table(name)
    end

    def tables : Array(OfflineTable)
      @catalog.tables(self)
    end
  end

  # Offline reader for the bounded ClickHouse 26.7 Atomic metadata layout.
  # It reads local files only and does not emulate system.* tables or server
  # lifecycle state.
  class OfflineCatalog
    MAX_METADATA_ENTRIES              =    10_000
    MAX_METADATA_BYTES                = 1_048_576
    MAX_IDENTIFIER_BYTES              =     4_096
    MAX_COUNT_BYTES                   =        32
    MAX_PART_CANDIDATES               =   100_000
    SYSTEM_DATABASE_NAME              = "system"
    SYSTEM_PART_CANDIDATES_TABLE_NAME = "part_candidates"
    TABLE_TAIL_CLAUSE_PATTERN         = /\A(PARTITION\s+BY|ORDER\s+BY|PRIMARY\s+KEY|SAMPLE\s+BY|TTL|SETTINGS|COMMENT)\b/i

    private struct DatabaseLocation
      getter uuid : String
      getter metadata_path : String

      def initialize(@uuid : String, @metadata_path : String)
      end
    end

    getter root : String

    def self.open(root : String) : OfflineCatalog
      new(root)
    end

    def initialize(root : String)
      expanded = File.expand_path(root)
      raise InvalidPartError.new("offline data root is a symbolic link") if File.symlink?(expanded)
      raise InvalidPartError.new("offline data root is not a directory") unless Dir.exists?(expanded)

      @root = canonical_root(expanded)
      raise InvalidPartError.new("offline data root cannot be the filesystem root") if @root == "/"
      validate_directory(File.join(@root, "metadata"), "metadata root")
      validate_directory(File.join(@root, "store"), "store root")
    end

    def database_names : Array(String)
      metadata_root = File.join(@root, "metadata")
      children = bounded_children(metadata_root, MAX_METADATA_ENTRIES, "database metadata entries")
      names = Array(String).new
      seen = Set(String).new

      children.each do |entry|
        next unless entry.ends_with?(".sql")

        path = File.join(metadata_root, entry)
        raise InvalidPartError.new("database DDL is a symbolic link: #{entry}") if File.symlink?(path)
        raise InvalidPartError.new("database DDL is not a regular file: #{entry}") unless File.file?(path)

        encoded_name = entry.byte_slice(0, entry.bytesize - 4)
        name = decode_identifier(encoded_name, "database metadata filename")
        raise InvalidPartError.new("duplicate decoded database name: #{name}") if seen.includes?(name)
        seen << name
        names << name
      end

      children.each do |entry|
        next if entry.ends_with?(".sql")

        path = File.join(metadata_root, entry)
        if entry == "default" && File.symlink?(path)
          uuid = uuid_from_metadata_link(path)
          validate_store_directory(uuid)
          unless seen.includes?("default")
            names << "default"
            seen << "default"
          end
        elsif File.symlink?(path) && seen.includes?(decode_identifier(entry, "database metadata alias"))
          # Non-default metadata/<database> links are ClickHouse convenience
          # links; table lookup validates them against the DDL UUID before use.
          next
        else
          raise InvalidPartError.new("unexpected entry in database metadata root: #{entry}")
        end
      end

      names.sort!
      names
    end

    def databases : Array(OfflineDatabase)
      names = database_names
      known_names = Set(String).new
      names.each { |name| known_names << name }
      names.map do |name|
        location = resolve_database(name, known_names)
        OfflineDatabase.new(self, name, location.uuid)
      end
    end

    def database(name : String) : OfflineDatabase
      validate_identifier(name, "database name")
      if name == SYSTEM_DATABASE_NAME
        raise InvalidPartError.new("physical database named system collides with the synthetic system database") if database_names.includes?(SYSTEM_DATABASE_NAME)
        return OfflineDatabase.new(self, SYSTEM_DATABASE_NAME, nil, true)
      end

      location = resolve_database(name)
      OfflineDatabase.new(self, name, location.uuid)
    end

    def [](name : String) : OfflineDatabase
      database(name)
    end

    def table_names(database : String) : Array(String)
      return self.database(database).table_names if database == SYSTEM_DATABASE_NAME

      location = resolve_database(database)
      list_table_names(location)
    end

    def table_names(database : OfflineDatabase) : Array(String)
      validate_database_owner!(database)
      if database.virtual_system?
        validate_virtual_system_database!(database)
        return [SYSTEM_PART_CANDIDATES_TABLE_NAME]
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      list_table_names(location)
    end

    def tables(database : OfflineDatabase) : Array(OfflineTable)
      validate_database_owner!(database)
      if database.virtual_system?
        validate_virtual_system_database!(database)
        return [part_candidates_table]
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      names = list_table_names(location)
      known_names = Set(String).new
      names.each { |name| known_names << name }
      result = Array(OfflineTable).new(names.size)
      names.each do |name|
        result << table(location, name, known_names)
      end
      result
    end

    # Materialize one selected column from the bounded synthetic
    # system.part_candidates projection. The result is owned by the caller and
    # returned only after all supported source tables, counts, and overlap
    # guards pass.
    def part_candidates_values(
      column_name : String,
      max_rows : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ROWS,
      max_string_bytes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
    ) : Array(OfflineColumnValue)
      unless {"database", "table", "name", "partition_id", "rows"}.includes?(column_name)
        raise UnsupportedFormatError.new("selected system.part_candidates column is unsupported")
      end
      raise BoundsError.new("selected column row limit exceeds hard limit") if max_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS
      raise BoundsError.new("selected column String payload limit exceeds hard limit") if max_string_bytes > OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES
      database_names = self.database_names
      if database_names.includes?(SYSTEM_DATABASE_NAME)
        raise InvalidPartError.new("physical database named system collides with the synthetic system database")
      end

      parts = Array({String, String, OfflinePartCandidate}).new
      known_database_names = Set(String).new
      database_names.each { |name| known_database_names << name }

      database_names.each do |database_name|
        location = resolve_database(database_name, known_database_names)
        table_names = list_table_names(location)
        known_table_names = Set(String).new
        table_names.each { |name| known_table_names << name }

        table_names.each do |table_name|
          table = table(location, table_name, known_table_names, parts.size)
          if table.engine == "MergeTree"
            candidates = table.part_candidates
            reject_part_candidate_overlaps!(table.name, candidates)
            candidates.each do |candidate|
              if parts.size.to_u64 >= max_rows
                raise BoundsError.new("selected column materialization exceeds row limit")
              end
              ensure_candidate_capacity!(parts.size + 1)
              parts << {database_name, table.name, candidate}
            end
          elsif merge_tree_family_engine?(table.engine)
            raise UnsupportedFormatError.new("system.part_candidates does not support MergeTree-family engine: #{table.engine}")
          end
        end
      end

      values = Array(OfflineColumnValue).new(parts.size)
      string_bytes = 0_u64
      parts.each do |database_name, table_name, candidate|
        value = case column_name
                when "database"     then database_name
                when "table"        then table_name
                when "name"         then candidate.name
                when "partition_id" then candidate.info.partition_id
                when "rows"         then candidate.row_count
                else                     raise UnsupportedFormatError.new("selected system.part_candidates column is unsupported")
                end
        if string_value = value.as?(String)
          byte_count = string_value.bytesize.to_u64
          if string_bytes > max_string_bytes || byte_count > max_string_bytes - string_bytes
            raise BoundsError.new("selected column materialization exceeds String payload limit")
          end
          string_bytes += byte_count
          value = String.new(string_value.to_slice)
        end
        values << value
      end
      values
    end

    private def list_table_names(location : DatabaseLocation) : Array(String)
      children = bounded_children(location.metadata_path, MAX_METADATA_ENTRIES, "table metadata entries")
      names = Array(String).new
      seen = Set(String).new

      children.each do |entry|
        unless entry.ends_with?(".sql")
          raise InvalidPartError.new("unexpected entry in table metadata directory: #{entry}")
        end

        path = File.join(location.metadata_path, entry)
        raise InvalidPartError.new("table DDL is a symbolic link: #{entry}") if File.symlink?(path)
        raise InvalidPartError.new("table DDL is not a regular file: #{entry}") unless File.file?(path)

        encoded_name = entry.byte_slice(0, entry.bytesize - 4)
        name = decode_identifier(encoded_name, "table metadata filename")
        raise InvalidPartError.new("duplicate decoded table name: #{name}") if seen.includes?(name)
        seen << name
        names << name
      end

      names.sort!
      names
    end

    def table(database : String, name : String) : OfflineTable
      validate_identifier(name, "table name")
      return self.database(database).table(name) if database == SYSTEM_DATABASE_NAME

      location = resolve_database(database)
      table(location, name)
    end

    def table(database : OfflineDatabase, name : String) : OfflineTable
      validate_database_owner!(database)
      validate_identifier(name, "table name")
      if database.virtual_system?
        validate_virtual_system_database!(database)
        raise InvalidPartError.new("table does not exist: #{name}") unless name == SYSTEM_PART_CANDIDATES_TABLE_NAME
        return part_candidates_table
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      table(location, name)
    end

    private def part_candidates_table : OfflineTable
      columns = [
        OfflineColumn.new("database", "String", false, false),
        OfflineColumn.new("table", "String", false, false),
        OfflineColumn.new("name", "String", false, false),
        OfflineColumn.new("partition_id", "String", false, false),
        OfflineColumn.new("rows", "UInt64", false, false),
      ] of OfflineColumn
      OfflineTable.new(SYSTEM_PART_CANDIDATES_TABLE_NAME, nil, "OfflineSystemPartCandidates", columns, nil, nil, self)
    end

    private def ensure_synthetic_system_available! : Nil
      if database_names.includes?(SYSTEM_DATABASE_NAME)
        raise InvalidPartError.new("physical database named system collides with the synthetic system database")
      end
    end

    private def validate_virtual_system_database!(database : OfflineDatabase) : Nil
      unless database.name == SYSTEM_DATABASE_NAME
        raise InvalidPartError.new("synthetic system database has an invalid name")
      end
      ensure_synthetic_system_available!
    end

    private def max_projected_candidates : Int32
      MAX_PART_CANDIDATES
    end

    private def ensure_candidate_capacity!(projected_candidates : Int32) : Nil
      raise BoundsError.new("system.part_candidates projected candidate count exceeds limit") if projected_candidates > max_projected_candidates
    end

    private def merge_tree_family_engine?(engine : String) : Bool
      engine.downcase.ends_with?("mergetree")
    end

    private def reject_part_candidate_overlaps!(table_name : String, candidates : Array(OfflinePartCandidate)) : Nil
      candidates.each_with_index do |left, left_index|
        right_index = left_index + 1
        while right_index < candidates.size
          right = candidates[right_index]
          if left.info.overlaps?(right.info)
            raise InvalidPartError.new("system.part_candidates refuses overlapping candidates for #{table_name}: #{left.name} and #{right.name}")
          end
          right_index += 1
        end
      end
    end

    private def table(location : DatabaseLocation, name : String) : OfflineTable
      names = list_table_names(location)
      known_names = Set(String).new
      names.each { |table_name| known_names << table_name }
      table(location, name, known_names)
    end

    private def table(
      location : DatabaseLocation,
      name : String,
      known_names : Set(String),
      projected_candidate_offset : Int32? = nil,
    ) : OfflineTable
      validate_identifier(name, "table name")
      raise InvalidPartError.new("table does not exist: #{name}") unless known_names.includes?(name)

      ddl_path = File.join(location.metadata_path, "#{encode_identifier(name)}.sql")
      ddl = read_bounded_file(ddl_path, MAX_METADATA_BYTES, "table DDL")
      uuid, columns, engine, primary_key_column = parse_table_ddl(ddl)

      part_candidates = if engine == "MergeTree"
                          table_path = validate_store_directory(uuid)
                          discover_part_candidates(table_path, projected_candidate_offset)
                        else
                          nil
                        end

      OfflineTable.new(name, uuid, engine, columns, part_candidates, primary_key_column)
    end

    private def validate_database_identity!(database : OfflineDatabase, location : DatabaseLocation) : Nil
      unless location.uuid == database.uuid
        raise InvalidPartError.new("database identity changed since object creation: #{database.name}")
      end
    end

    private def validate_database_owner!(database : OfflineDatabase) : Nil
      unless database.owned_by?(self)
        raise InvalidPartError.new("database object belongs to a different offline catalog")
      end
    end

    private def resolve_database(name : String, known_names : Set(String)? = nil) : DatabaseLocation
      validate_identifier(name, "database name")
      exists = if known_names
                 known_names.includes?(name)
               else
                 database_names.includes?(name)
               end
      raise InvalidPartError.new("database does not exist: #{name}") unless exists

      metadata_root = File.join(@root, "metadata")
      ddl_path = File.join(metadata_root, "#{encode_identifier(name)}.sql")
      uuid = if File.file?(ddl_path) && !File.symlink?(ddl_path)
               parse_database_ddl(read_bounded_file(ddl_path, MAX_METADATA_BYTES, "database DDL"))
             elsif name == "default"
               link_path = File.join(metadata_root, "default")
               raise InvalidPartError.new("default metadata entry must be a symbolic link") unless File.symlink?(link_path)
               uuid_from_metadata_link(link_path)
             else
               raise InvalidPartError.new("database DDL is missing: #{name}")
             end

      store_path = validate_store_directory(uuid)
      alias_path = File.join(metadata_root, encode_identifier(name))
      if File.symlink?(alias_path)
        expected_link = "../store/#{uuid[0, 3]}/#{uuid}"
        actual_link = File.readlink(alias_path)
        raise InvalidPartError.new("database metadata symlink is not canonical: #{name}") unless actual_link == expected_link
        resolved_link = File.realpath(alias_path)
        raise InvalidPartError.new("database metadata symlink escapes the data root: #{name}") unless resolved_link == store_path && path_within_root?(resolved_link)
      elsif File.exists?(alias_path)
        raise InvalidPartError.new("database metadata alias is not a symbolic link: #{name}")
      elsif File.symlink?(alias_path)
        # A dangling link is still an invalid metadata alias.
        raise InvalidPartError.new("database metadata symlink is dangling: #{name}")
      end

      DatabaseLocation.new(uuid, store_path)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot resolve database metadata")
    end

    private def parse_database_ddl(ddl : String) : String
      match = /\A\s*ATTACH\s+DATABASE\s+_\s+UUID\s+'([^']+)'\s+ENGINE\s*=\s*([A-Za-z][A-Za-z0-9_]*)\s*;?\s*\z/i.match(ddl)
      raise UnsupportedFormatError.new("unsupported Atomic database DDL") unless match
      engine = match[2]
      raise UnsupportedFormatError.new("offline catalog supports Atomic databases only") unless engine.compare("Atomic", case_insensitive: true) == 0
      normalize_uuid(match[1])
    end

    private def parse_table_ddl(ddl : String) : {String, Array(OfflineColumn), String, String?}
      header = /\A\s*ATTACH\s+TABLE\s+_\s+UUID\s+'([^']+)'\s*\(/i.match(ddl)
      raise UnsupportedFormatError.new("unsupported table DDL header") unless header
      uuid = normalize_uuid(header[1])

      opening = header.end(0) - 1
      closing = matching_parenthesis(ddl, opening)
      columns_text = ddl.byte_slice(opening + 1, closing - opening - 1)
      tail = ddl.byte_slice(closing + 1, ddl.bytesize - closing - 1)
      engine_match = /\A\s*ENGINE\s*=\s*([A-Za-z][A-Za-z0-9_]*)\b/i.match(tail)
      raise UnsupportedFormatError.new("unsupported table DDL engine clause") unless engine_match
      engine = engine_match[1]
      trailing = tail.byte_slice(engine_match.end(0), tail.bytesize - engine_match.end(0)).strip
      unless trailing.empty? || supported_table_tail?(trailing)
        raise UnsupportedFormatError.new("unsupported table DDL suffix")
      end

      columns = parse_columns(columns_text)
      primary_key_column = engine.compare("MergeTree", case_insensitive: true) == 0 ? parse_simple_order_key(trailing, columns) : nil
      {uuid, columns, engine, primary_key_column}
    end

    private def supported_table_tail?(trailing : String) : Bool
      return false unless /\A(?:ORDER\s+BY|PRIMARY\s+KEY|PARTITION\s+BY|SAMPLE\s+BY|TTL|SETTINGS|COMMENT)\b/i.matches?(trailing)

      !contains_unsupported_table_tail_control?(trailing)
    end

    # Extract only an exact one-column ascending ORDER BY key and optional
    # identical PRIMARY KEY. Other recognized MergeTree clauses are split at
    # top-level boundaries but never interpreted for pruning.
    private def parse_simple_order_key(trailing : String, columns : Array(OfflineColumn)) : String?
      return nil if trailing.empty?
      clauses = split_table_tail_clauses(trailing)
      return nil unless clauses

      order_clauses = clauses.not_nil!.select { |clause| clause[0] == "ORDER BY" }
      return nil unless order_clauses.size == 1
      order_column = parse_simple_ascending_key_expression(order_clauses[0][1])
      return nil unless order_column

      primary_clauses = clauses.not_nil!.select { |clause| clause[0] == "PRIMARY KEY" }
      return nil if primary_clauses.size > 1
      if primary_clause = primary_clauses.first?
        primary_column = parse_simple_ascending_key_expression(primary_clause[1])
        return nil unless primary_column == order_column
      end

      column = columns.find { |entry| entry.name == order_column }
      return nil unless column && column.type == "UInt64" && !column.alias_column && column.key_candidate_column
      return nil unless supported_pk_suffix_clauses?(clauses.not_nil!)
      order_column
    end

    private def supported_pk_suffix_clauses?(clauses : Array({String, String})) : Bool
      previous_rank = -1
      clauses.each do |keyword, content|
        rank = case keyword
               when "PARTITION BY"            then 0
               when "PRIMARY KEY", "ORDER BY" then 1
               when "SAMPLE BY"               then 2
               when "TTL"                     then 3
               when "SETTINGS"                then 4
               when "COMMENT"                 then 5
               else                                return false
               end
        # ClickHouse accepts PRIMARY KEY on either side of ORDER BY. Those
        # two clauses may therefore share a rank, but other suffix clauses
        # must remain in their canonical increasing order.
        return false if rank < previous_rank || (rank == previous_rank && rank != 1)
        return false unless supported_pk_suffix_clause?(keyword, content)
        previous_rank = rank
      end
      true
    end

    # This is intentionally a narrow suffix validator, not a general DDL
    # parser. It prevents opaque clause text from swallowing trailing tokens
    # while retaining common partitioned tables and simple SETTINGS metadata.
    private def supported_pk_suffix_clause?(keyword : String, content : String) : Bool
      case keyword
      when "PARTITION BY"
        supported_simple_partition_expression?(content)
      when "ORDER BY", "PRIMARY KEY", "SAMPLE BY"
        !!parse_simple_ascending_key_expression(content)
      when "SETTINGS"
        supported_simple_settings?(content)
      when "COMMENT"
        /\A'(?:[^']|'')*'\z/m.matches?(content)
      else
        false
      end
    end

    private def supported_simple_partition_expression?(content : String) : Bool
      identifier = "(?:`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*)"
      return true if Regex.new("\\A#{identifier}\\z").matches?(content.strip)
      return true if /\Atuple\s*\(\s*\)\z/i.matches?(content.strip)
      Regex.new("\\A[A-Za-z_][A-Za-z0-9_]*\\s*\\(\\s*#{identifier}(?:\\s*,\\s*#{identifier})*\\s*\\)\\z").matches?(content.strip)
    end

    private def supported_simple_settings?(content : String) : Bool
      setting = "[A-Za-z_][A-Za-z0-9_]*"
      value = "(?:'[^']*'|\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*|[0-9]+(?:\\.[0-9]+)?)"
      Regex.new("\\A#{setting}\\s*=\\s*#{value}(?:\\s*,\\s*#{setting}\\s*=\\s*#{value})*\\z").matches?(content.strip)
    end

    private def split_table_tail_clauses(text : String) : Array({String, String})?
      clauses = Array({String, String}).new
      cursor = 0
      while cursor < text.bytesize
        while cursor < text.bytesize && whitespace?(text.to_slice[cursor])
          cursor += 1
        end
        break if cursor == text.bytesize

        match = TABLE_TAIL_CLAUSE_PATTERN.match(text.byte_slice(cursor, text.bytesize - cursor))
        return nil unless match
        keyword = match[1].gsub(/\s+/, " ").upcase
        content_start = cursor + match.end(0)
        next_clause = find_next_table_tail_clause(text, content_start)
        content_end = next_clause || text.bytesize
        content = text.byte_slice(content_start, content_end - content_start).strip
        return nil if content.empty?
        return nil if clauses.any? { |clause| clause[0] == keyword }

        clauses << {keyword, content}
        cursor = content_end
      end
      clauses
    end

    private def find_next_table_tail_clause(text : String, start : Int32) : Int32?
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = start
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif quote == '`'.ord && byte == '`'.ord && index + 1 < bytes.size && bytes[index + 1] == '`'.ord
            index += 1
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return nil if depth < 0
        elsif depth == 0 && whitespace?(byte)
          candidate = index
          while candidate < bytes.size && whitespace?(bytes[candidate])
            candidate += 1
          end
          if candidate > index && candidate < bytes.size && TABLE_TAIL_CLAUSE_PATTERN.matches?(text.byte_slice(candidate, bytes.size - candidate))
            return candidate
          end
        end
        index += 1
      end

      nil if depth != 0 || quote != 0 || escaped
    end

    private def parse_simple_ascending_key_expression(expression : String) : String?
      match = /\A(?:`([A-Za-z_][A-Za-z0-9_]*)`|([A-Za-z_][A-Za-z0-9_]*))(?:\s+ASC)?\z/i.match(expression.strip)
      return nil unless match
      match[1]? || match[2]?
    end

    # This guards the supported generated-DDL subset; it is not a general SQL
    # validator. It rejects statement/comment boundaries and a second
    # top-level ENGINE assignment without interpreting clause semantics.
    private def contains_unsupported_table_tail_control?(text : String) : Bool
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = 0

      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return true if depth < 0
        elsif byte == ';'.ord || byte == '#'.ord ||
              (byte == '-'.ord && index + 1 < bytes.size && bytes[index + 1] == '-'.ord) ||
              (byte == '/'.ord && index + 1 < bytes.size && bytes[index + 1] == '*'.ord)
          return true
        elsif depth == 0 && engine_assignment_at?(text, bytes, index)
          return true
        end
        index += 1
      end

      depth != 0 || quote != 0 || escaped
    end

    private def engine_assignment_at?(text : String, bytes : Bytes, index : Int32) : Bool
      return false if index + 6 > bytes.size
      return false unless text.byte_slice(index, 6).compare("ENGINE", case_insensitive: true) == 0
      return false if index > 0 && identifier_byte?(bytes[index - 1])
      return false if index + 6 < bytes.size && identifier_byte?(bytes[index + 6])

      cursor = index + 6
      while cursor < bytes.size && whitespace?(bytes[cursor])
        cursor += 1
      end
      cursor < bytes.size && bytes[cursor] == '='.ord
    end

    private def identifier_byte?(byte : UInt8) : Bool
      byte >= 'a'.ord && byte <= 'z'.ord ||
        byte >= 'A'.ord && byte <= 'Z'.ord ||
        byte >= '0'.ord && byte <= '9'.ord ||
        byte == '_'.ord
    end

    private def parse_columns(text : String) : Array(OfflineColumn)
      definitions = split_top_level(text, "column list")
      raise UnsupportedFormatError.new("table DDL has no columns") if definitions.empty?
      raise BoundsError.new("table column count exceeds limit") if definitions.size > 4_096

      columns = Array(OfflineColumn).new(definitions.size)
      seen = Set(String).new
      definitions.each do |definition|
        name, type, alias_column, key_candidate_column = parse_column_definition(definition)
        raise UnsupportedFormatError.new("duplicate table column name: #{name}") if seen.includes?(name)
        seen << name
        columns << OfflineColumn.new(name, type, alias_column, key_candidate_column)
      end
      columns
    end

    private def parse_column_definition(definition : String) : {String, String, Bool, Bool}
      source = definition.strip
      bytes = source.to_slice
      raise UnsupportedFormatError.new("unsupported table column definition") if bytes.empty? || bytes[0] != '`'.ord

      index = 1
      closed = false
      name = String.build do |io|
        while index < bytes.size
          byte = bytes[index]
          if byte == '\\'.ord
            index += 1
            raise UnsupportedFormatError.new("unterminated escaped column name") if index >= bytes.size
            io.write_byte(bytes[index])
          elsif byte == '`'.ord
            closed = true
            index += 1
            break
          else
            io.write_byte(byte)
          end
          index += 1
        end
      end
      raise UnsupportedFormatError.new("unterminated column name") unless closed
      raise UnsupportedFormatError.new("column name is empty or exceeds limit") if name.empty? || name.bytesize > MAX_IDENTIFIER_BYTES
      raise UnsupportedFormatError.new("invalid UTF-8 table column name") unless name.valid_encoding?

      while index < bytes.size && whitespace?(bytes[index])
        index += 1
      end
      raise UnsupportedFormatError.new("column type is missing") if index >= bytes.size

      type_start = index
      type_end = find_column_type_end(source, type_start)
      type = source.byte_slice(type_start, type_end - type_start).strip
      raise UnsupportedFormatError.new("column type is empty") if type.empty?

      modifier = source.byte_slice(type_end, source.bytesize - type_end).strip
      unless modifier.empty? || column_modifier?(modifier)
        raise UnsupportedFormatError.new("unsupported table column modifier")
      end

      {name, type, /\AALIAS\b/i.matches?(modifier), modifier.empty?}
    end

    private def find_column_type_end(source : String, start : Int32) : Int32
      bytes = source.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = start
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("unbalanced column type") if depth < 0
        elsif depth == 0 && whitespace?(byte)
          cursor = index
          while cursor < bytes.size && whitespace?(bytes[cursor])
            cursor += 1
          end
          if cursor == bytes.size
            return index
          elsif column_modifier?(source.byte_slice(cursor).strip)
            return index
          else
            raise UnsupportedFormatError.new("unsupported whitespace in column type")
          end
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unbalanced column type") unless depth == 0 && quote == 0
      bytes.size
    end

    private def column_modifier?(text : String) : Bool
      /\A(?:DEFAULT|MATERIALIZED|ALIAS|CODEC|COMMENT|TTL)\b/i.matches?(text)
    end

    private def split_top_level(text : String, context : String) : Array(String)
      bytes = text.to_slice
      values = Array(String).new
      depth = 0
      quote = 0_u8
      escaped = false
      start = 0
      index = 0
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("unbalanced #{context}") if depth < 0
        elsif byte == ','.ord && depth == 0
          values << text.byte_slice(start, index - start).strip
          start = index + 1
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unbalanced #{context}") unless depth == 0 && quote == 0 && !escaped
      final = text.byte_slice(start, bytes.size - start).strip
      raise UnsupportedFormatError.new("empty #{context} entry") if final.empty? || values.any?(&.empty?)
      values << final
      values
    end

    private def matching_parenthesis(text : String, opening : Int32) : Int32
      bytes = text.to_slice
      depth = 1
      quote = 0_u8
      escaped = false
      index = opening + 1
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return index if depth == 0
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unterminated table column list")
    end

    private def discover_part_candidates(table_path : String, projected_candidate_offset : Int32? = nil) : Array(OfflinePartCandidate)
      children = bounded_children(table_path, WidePartTable::MAX_PARTS + 2_048, "table data entries")
      candidates = Array(OfflinePartCandidate).new
      total_rows = 0_u64

      children.each do |name|
        path = File.join(table_path, name)
        raise InvalidPartError.new("symbolic link in table data directory: #{name}") if File.symlink?(path)

        if name == "detached" || name.starts_with?("tmp") || name.starts_with?("delete_tmp_")
          raise InvalidPartError.new("detached or temporary entry is not a directory: #{name}") unless Dir.exists?(path)
          next
        end

        info = MergeTreePartInfo.parse(name)
        unless info
          if MergeTreePartInfo.part_like?(name) || Dir.exists?(path) && name.split('_').size >= 3
            raise InvalidPartError.new("malformed part-like directory name: #{name}")
          end
          next
        end

        raise InvalidPartError.new("part candidate is not a physical directory: #{name}") unless Dir.exists?(path)
        raise UnsupportedFormatError.new("patch parts are not supported: #{name}") if info.patch?
        raise BoundsError.new("part count exceeds limit") if candidates.size >= WidePartTable::MAX_PARTS
        if offset = projected_candidate_offset
          ensure_candidate_capacity!(offset + candidates.size + 1)
        end

        count_path = File.join(path, "count.txt")
        row_count = parse_row_count(read_bounded_file(count_path, MAX_COUNT_BYTES, "part row count"))
        raise BoundsError.new("table candidate row count exceeds limit") if row_count > WidePartTable::MAX_TOTAL_ROWS - total_rows
        total_rows += row_count
        candidates << OfflinePartCandidate.new(name, path, info, row_count)
      end

      candidates.sort_by!(&.name)
      candidates
    end

    private def parse_row_count(text : String) : UInt64
      value = text
      value = value.byte_slice(0, value.bytesize - 1) if value.ends_with?('\n')
      raise CorruptPartError.new("invalid part row count") if value.empty? || value.bytesize > 20

      result = 0_u64
      value.each_byte do |byte|
        raise CorruptPartError.new("invalid part row count") unless byte >= '0'.ord && byte <= '9'.ord
        digit = (byte - '0'.ord).to_u64
        raise CorruptPartError.new("part row count overflows UInt64") if result > (UInt64::MAX - digit) // 10
        result = result * 10 + digit
      end
      raise CorruptPartError.new("physical part has zero rows") if result == 0
      result
    end

    private def parse_default_metadata_link(path : String) : String
      target = File.readlink(path)
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match(target)
      raise InvalidPartError.new("default metadata symlink target is not canonical") unless match

      uuid = normalize_uuid(match[2])
      raise InvalidPartError.new("default metadata symlink prefix does not match UUID") unless match[1] == uuid[0, 3]
      expected = File.join(@root, "store", uuid[0, 3], uuid)
      resolved = File.realpath(path)
      raise InvalidPartError.new("default metadata symlink escapes the data root") unless resolved == expected && path_within_root?(resolved)
      uuid
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot resolve default metadata symlink")
    end

    private def uuid_from_metadata_link(path : String) : String
      parse_default_metadata_link(path)
    end

    private def validate_store_directory(uuid : String) : String
      normalized = normalize_uuid(uuid)
      prefix_path = File.join(@root, "store", normalized[0, 3])
      validate_directory(prefix_path, "UUID store prefix")
      store_path = File.join(prefix_path, normalized)
      validate_directory(store_path, "UUID store directory")
      store_path
    end

    private def validate_directory(path : String, context : String) : Nil
      raise InvalidPartError.new("#{context} is a symbolic link") if File.symlink?(path)
      raise InvalidPartError.new("#{context} is not a directory") unless Dir.exists?(path)
      resolved = File.realpath(path)
      raise InvalidPartError.new("#{context} escapes the offline data root") unless resolved == path && path_within_root?(resolved)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot validate #{context}")
    end

    private def bounded_children(path : String, limit : Int32, context : String) : Array(String)
      children = Array(String).new
      Dir.each_child(path) do |name|
        raise BoundsError.new("#{context} exceed limit") if children.size >= limit
        children << name
      end
      children.sort!
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot enumerate #{context}")
    end

    private def read_bounded_file(path : String, limit : Int32, context : String) : String
      raise InvalidPartError.new("#{context} is a symbolic link") if File.symlink?(path)
      raise InvalidPartError.new("#{context} is not a regular file") unless File.file?(path)

      String.build do |output|
        File.open(path, "r") do |input|
          buffer = Bytes.new(8_192)
          total = 0
          while (read = input.read(buffer)) > 0
            raise BoundsError.new("#{context} exceeds size limit") if read > limit - total
            output.write(buffer[0, read])
            total += read
          end
        end
      end
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read #{context}")
    end

    private def decode_identifier(encoded : String, context : String) : String
      raise BoundsError.new("#{context} exceeds size limit") if encoded.bytesize > MAX_IDENTIFIER_BYTES * 3
      source = encoded.to_slice
      decoded = Bytes.new(source.size)
      input = 0
      output = 0
      while input < source.size
        byte = source[input]
        if byte == '%'.ord
          raise InvalidPartError.new("malformed escaped byte in #{context}") if input + 2 >= source.size
          high = hex_value(source[input + 1])
          low = hex_value(source[input + 2])
          raise InvalidPartError.new("malformed escaped byte in #{context}") unless high && low
          decoded[output] = (high * 16 + low).to_u8
          input += 3
        else
          raise InvalidPartError.new("noncanonical raw byte in #{context}") unless ascii_word_byte?(byte)
          decoded[output] = byte
          input += 1
        end
        output += 1
      end

      name = String.new(decoded[0, output])
      raise InvalidPartError.new("invalid UTF-8 in #{context}") unless name.valid_encoding?
      validate_identifier(name, context)
      raise InvalidPartError.new("noncanonical escaped filename in #{context}") unless encode_identifier(name) == encoded
      name
    end

    private def encode_identifier(name : String) : String
      String.build do |io|
        name.each_byte do |byte|
          if ascii_word_byte?(byte)
            io.write_byte(byte)
          else
            io << '%' << byte.to_s(16).upcase.rjust(2, '0')
          end
        end
      end
    end

    private def validate_identifier(name : String, context : String) : Nil
      raise InvalidPartError.new("empty #{context}") if name.empty?
      raise BoundsError.new("#{context} exceeds size limit") if name.bytesize > MAX_IDENTIFIER_BYTES
      raise InvalidPartError.new("invalid UTF-8 in #{context}") unless name.valid_encoding?
    end

    private def ascii_word_byte?(byte : UInt8) : Bool
      byte >= 'a'.ord && byte <= 'z'.ord ||
        byte >= 'A'.ord && byte <= 'Z'.ord ||
        byte >= '0'.ord && byte <= '9'.ord ||
        byte == '_'.ord
    end

    private def hex_value(byte : UInt8) : UInt8?
      if byte >= '0'.ord && byte <= '9'.ord
        (byte - '0'.ord).to_u8
      elsif byte >= 'A'.ord && byte <= 'F'.ord
        (byte - 'A'.ord + 10).to_u8
      else
        nil
      end
    end

    private def normalize_uuid(text : String) : String
      unless /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.matches?(text)
        raise UnsupportedFormatError.new("invalid UUID in ClickHouse metadata")
      end
      text.downcase
    end

    private def path_within_root?(path : String) : Bool
      path == @root || path.starts_with?(@root + "/")
    end

    private def canonical_root(path : String) : String
      File.realpath(path)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read offline data root")
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\r'.ord || byte == '\n'.ord
    end
  end
end
