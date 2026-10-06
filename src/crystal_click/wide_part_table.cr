module CrystalClick
  # A correctness-first reader over caller-selected immutable Wide-part paths.
  # It does not discover active parts or execute a query language. Each mark is
  # materialized for selected columns, checked for row alignment, then exposed
  # in bounded callback slices.
  class WidePartTable
    MAX_PARTS             = 1_024
    MAX_COLUMNS           =    16
    MAX_PART_NAME_BYTES   = MergeTreePartInfo::MAX_NAME_BYTES
    MAX_PART_PATH_BYTES   =         4_096
    MAX_COLUMN_NAME_BYTES =         4_096
    MAX_MARKS_PER_READER  =        65_536
    MAX_TOTAL_MARKS       = 1_000_000_u64
    # At the 16-column limit a full mark is capped at 8 MiB for the widest types.
    MAX_MARK_ROWS = 65_536_u64
    # Selected String-like payloads are preflighted and then rechecked after
    # materialization; one mark is capped independently of batch_rows.
    MAX_MARK_MATERIALIZED_BYTES = 64 * 1024 * 1024
    MAX_TOTAL_ROWS              = 100_000_000_000_u64
    DEFAULT_BATCH_ROWS          =               4_096
    MAX_BATCH_ROWS              =               4_096

    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private struct ColumnReader
      getter name : String
      getter reader : WidePart

      def column_type : String
        @reader.column_type
      end

      def initialize(@name : String, @reader : WidePart)
      end
    end

    private struct ObjectColumnReaderEntry
      getter name : String
      getter reader : ObjectColumnReader
      getter column_type : String

      def initialize(@name : String, @reader : ObjectColumnReader, @column_type : String)
      end
    end

    private struct ArrayObjectColumnReaderEntry
      getter name : String
      getter reader : ArrayObjectColumnReader
      getter column_type : String

      def initialize(@name : String, @reader : ArrayObjectColumnReader, @column_type : String)
      end
    end

    private struct RecursiveColumnReaderEntry
      getter name : String
      getter reader : RecursiveStorageColumnReader
      getter schema : StorageColumnSchema
      getter column_type : String

      def initialize(@name : String, @reader : RecursiveStorageColumnReader, @schema : StorageColumnSchema, @column_type : String)
      end
    end

    private struct PartEntry
      getter name : String
      getter path : String
      getter row_count : UInt64
      getter mark_row_counts : Array(UInt64)
      getter readers : Array(ColumnReader)
      getter aggregate_count_key_reader : ColumnReader?
      getter object_readers : Array(ObjectColumnReaderEntry)
      getter array_object_readers : Array(ArrayObjectColumnReaderEntry)
      getter recursive_readers : Array(RecursiveColumnReaderEntry)
      getter column_types : Array(String)
      getter column_sources : Array({String, String, String})

      def initialize(
        @name : String,
        @path : String,
        @row_count : UInt64,
        @mark_row_counts : Array(UInt64),
        @readers : Array(ColumnReader),
        @aggregate_count_key_reader : ColumnReader?,
        @object_readers : Array(ObjectColumnReaderEntry),
        @array_object_readers : Array(ArrayObjectColumnReaderEntry),
        @recursive_readers : Array(RecursiveColumnReaderEntry),
        @column_types : Array(String),
        @column_sources : Array({String, String, String}),
      )
      end
    end

    @columns : Array(String)
    @entries : Array(PartEntry)
    @numeric_mode : Bool
    @typed_mode : Bool
    @flattened_context : FlattenedNestedTableContext?

    def self.open_selected(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, false)
    end

    def self.open_selected_numeric(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, true, false)
    end

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, true)
    end

    # Read an explicit logical Nested root and/or its expected UInt64 key from
    # caller-selected flattened Wide-part paths. Ordinary table opens retain
    # their exact physical-column semantics.
    def self.open_selected_flattened_nested_typed(
      parts : Array(String),
      columns : Array(String),
      key_name : String,
      group_name : String,
      type_name : String,
    ) : WidePartTable
      context = FlattenedNestedTableContext.new(key_name, group_name, type_name)
      new(parts, columns, false, true, nil, context)
    end

    # Read a named physical projection from each caller-selected parent part.
    # Scan batches retain the parent identity while their readers and row
    # offsets use the projection's independent physical row and mark layout.
    def self.open_selected_projection_typed(parent_parts : Array(String), projection_name : String, columns : Array(String)) : WidePartTable
      new(parent_parts, columns, false, true, projection_name)
    end

    def columns : Array(String)
      if @flattened_context
        @columns.map { |column| String.new(column.to_slice) }
      else
        @columns.dup
      end
    end

    def column_types : Array({String, String})
      return [] of {String, String} if @entries.empty?
      types = @entries.first.column_types
      selected = Array({String, String}).new(@columns.size)
      @columns.each_with_index do |column, index|
        if @flattened_context
          selected << {String.new(column.to_slice), String.new(types[index].to_slice)}
        else
          selected << {column, types[index]}
        end
      end
      selected
    end

    # Retain the physical source identity for virtual JSON typed paths so the
    # offline table can compare full JSON schemas before exposing callbacks.
    def column_sources : Array({String, String, String})
      return [] of {String, String, String} if @entries.empty?
      @entries.first.column_sources.map do |column, source_name, source_type|
        if @flattened_context
          {String.new(column.to_slice), String.new(source_name.to_slice), String.new(source_type.to_slice)}
        else
          {column.dup, source_name.dup, source_type.dup}
        end
      end
    end

    # Return each selected part's data-mark row counts in physical part order.
    def part_mark_row_counts : Array(Array(UInt64))
      @entries.map { |part| part.mark_row_counts.dup }
    end

    # The callback receives one row-aligned slice per selected column. Slices
    # alias the current mark arrays and must not be retained past the callback.
    def scan(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.object_readers.empty? && part.array_object_readers.empty? && part.recursive_readers.empty? && part.readers.all? { |selected| selected.column_type == "UInt64" } }
        raise UnsupportedFormatError.new("UInt64 scan requires exact UInt64 columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan only the caller-selected data marks. Each callback receives one
    # complete candidate granule; skipped marks still advance physical row
    # offsets and are never materialized.
    def scan_candidate_marks(mark_indices : Array(Array(Int32)), & : WidePartTableBatch -> Nil) : Nil
      unless @entries.all? { |part| part.object_readers.empty? && part.array_object_readers.empty? && part.recursive_readers.empty? && part.readers.all? { |selected| selected.column_type == "UInt64" } }
        raise UnsupportedFormatError.new("UInt64 candidate scan requires exact UInt64 columns")
      end
      raise BoundsError.new("candidate mark list does not match selected parts") unless mark_indices.size == @entries.size

      # Validate the complete schedule before exposing the first callback.
      mark_indices.each_with_index do |part_marks, part_index|
        mark_count = @entries[part_index].mark_row_counts.size
        previous = -1
        part_marks.each do |mark_index|
          raise BoundsError.new("candidate mark index is out of range") if mark_index < 0 || mark_index >= mark_count
          raise BoundsError.new("candidate mark indices must be strictly increasing") if mark_index <= previous
          previous = mark_index
        end
      end

      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        selected_marks = mark_indices[part_index]
        selected_index = 0
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          if selected_index < selected_marks.size && selected_marks[selected_index] == mark_index.to_i32
            selected_index += 1
            column_values = Array(WidePartNumericArray).new(@columns.size)
            part.readers.each do |selected|
              values = read_numeric_values(selected, mark_index)
              raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
              column_values << values
            end

            slices = Array(WidePartNumericSlice).new(column_values.size)
            column_values.each do |values|
              slices << slice_numeric_values(values, 0, values.size)
            end
            yield WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              0_u64,
              part_row_offset,
              source_row_offset &+ part_row_offset,
              @columns,
              part.column_types,
              slices
            )
          end
          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during candidate scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    # Scan selected candidate marks through the typed reader. Every selected
    # mark is exposed in one callback, while unselected marks advance offsets
    # without reading any selected column data.
    def scan_typed_candidate_marks(mark_indices : Array(Array(Int32)), & : WidePartTableBatch -> Nil) : Nil
      raise UnsupportedFormatError.new("typed candidate scan requires typed readers") unless @typed_mode
      raise BoundsError.new("candidate mark list does not match selected parts") unless mark_indices.size == @entries.size

      # Snapshot and validate the complete schedule before any callback. This
      # prevents a callback from changing later selections through the caller's
      # mutable arrays.
      validated_mark_indices = Array(Array(Int32)).new(mark_indices.size)
      mark_indices.each_with_index do |part_marks, part_index|
        mark_count = @entries[part_index].mark_row_counts.size
        validated_part_marks = part_marks.dup
        previous = -1
        validated_part_marks.each do |mark_index|
          raise BoundsError.new("candidate mark index is out of range") if mark_index < 0 || mark_index >= mark_count
          raise BoundsError.new("candidate mark indices must be strictly increasing") if mark_index <= previous
          previous = mark_index
        end
        validated_mark_indices << validated_part_marks
      end

      # All source marks are bounded by MAX_MARK_ROWS, so this batch size emits
      # a selected granule as one complete callback. whole_marks also preserves
      # the one-callback contract for a selected zero-row mark.
      scan_typed_rows(MAX_MARK_ROWS.to_i, validated_mark_indices, whole_marks: true) { |batch| yield batch }
      nil
    end

    # Scan mixed fixed-width primitive numeric columns. Typed values are
    # retrieved from each batch with values_for(column, CrystalType).
    def scan_numeric(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.object_readers.empty? && part.array_object_readers.empty? && part.recursive_readers.empty? && part.readers.all? { |selected| WidePart.supports_numeric_type?(selected.column_type) } }
        raise UnsupportedFormatError.new("numeric scan requires exact primitive numeric columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan exact String, Date/Date32 raw day codes, primitive numeric, and
    # supported Nullable columns. Each selected column's declared type is
    # retained in the callback; no equal-width reinterpretation is permitted.
    def scan_typed(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      scan_typed_rows(batch_rows) { |batch| yield batch }
    end

    # Scan a bounded physical-row interval in caller-selected part order.
    # Only marks intersecting the interval have selected column payloads
    # materialized; each selected mark is still decoded under the existing
    # per-mark bounds, then the callback receives only the intersecting rows.
    def scan_typed_window(
      start_row : UInt64,
      max_rows : Int = DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      raise BoundsError.new("window row count is out of range") if max_rows <= 0 || max_rows > MAX_BATCH_ROWS
      raise BoundsError.new("window start is beyond the source row count") if start_row > @total_row_count
      return nil if start_row == @total_row_count

      available_rows = @total_row_count - start_row
      window_rows = max_rows.to_u64 < available_rows ? max_rows.to_u64 : available_rows
      # window_rows is bounded by total_row_count - start_row, so this addition
      # is checked by construction and cannot overflow UInt64.
      end_row = start_row + window_rows
      scan_typed_rows(max_rows, window_rows: {start_row, end_row}) { |batch| yield batch }
      nil
    end

    private def scan_typed_rows(
      batch_rows : Int,
      candidate_marks : Array(Array(Int32))? = nil,
      whole_marks : Bool = false,
      window_rows : {UInt64, UInt64}? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      # Validate selected W82/W83/W84 Array(Map) leaf marks before callbacks,
      # including later marks, so their corruption or combined nested-charge
      # overflow cannot surface after an earlier callback escapes. This is
      # intentionally not a whole-scan atomicity promise for other codecs.
      validate_complete_array_object_schedules
      validate_complete_recursive_schedules
      preflight_coordinate_selected_marks(candidate_marks, window_rows)
      preflight_array_map_leaf_selected_marks(candidate_marks, window_rows)

      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        begin
          part_row_offset = 0_u64
          selected_marks = candidate_marks ? candidate_marks[part_index] : nil
          selected_index = 0
          part.mark_row_counts.each_with_index do |mark_rows, mark_index|
            mark_start_part_row_offset = part_row_offset
            part_row_offset &+= mark_rows

            selected_mark = true
            if part_marks = selected_marks
              selected_mark = selected_index < part_marks.size && part_marks[selected_index] == mark_index
              selected_index += 1 if selected_mark
            end
            next unless selected_mark

            selected_mark_row_start = 0_u64
            selected_mark_row_end = mark_rows
            if window = window_rows
              mark_source_start = source_row_offset &+ mark_start_part_row_offset
              mark_source_end = mark_source_start &+ mark_rows
              window_start, window_end = window
              next if mark_rows == 0_u64 || window_start >= mark_source_end || window_end <= mark_source_start

              selected_mark_row_start = window_start > mark_source_start ? window_start - mark_source_start : 0_u64
              selected_mark_row_end = window_end < mark_source_end ? window_end - mark_source_start : mark_rows
            end

            # Selected String, Nullable(String), and fixed-width String payloads are
            # preflighted before any String array is allocated. The immutable-
            # parts contract is not transactional; the actual aggregate is
            # checked again before callback exposure.
            preflight_string_bytes = 0_u64
            preflight_aggregate_count_charges = Hash(String, UInt64).new
            preflight_simple_aggregate_text_bytes = Hash(String, UInt64).new
            preflight_qbit_charges = Hash(String, UInt64).new
            preflight_point_charges = Hash(String, UInt64).new
            preflight_geometry_charges = Hash(String, UInt64).new
            preflight_geo_array_charges = Hash(String, UInt64).new
            preflight_array_numeric_bytes = Hash(String, UInt64).new
            preflight_array_nullable_numeric_bytes = Hash(String, UInt64).new
            preflight_array_uuid_bytes = Hash(String, UInt64).new
            preflight_array_nullable_uuid_bytes = Hash(String, UInt64).new
            preflight_array_array_uint64_bytes = Hash(String, UInt64).new
            preflight_array_array_string_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_string_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_uint64_bytes = Hash(String, UInt64).new
            preflight_array_array_numeric_bytes = Hash(String, UInt64).new
            preflight_array_array_nullable_numeric_bytes = Hash(String, UInt64).new
            preflight_array_nullable_string_raw_bytes = Hash(String, UInt64).new
            preflight_array_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_array_tuple_bytes = Hash(String, UInt64).new
            preflight_array_tuple_reader_charges = Hash(String, UInt64).new
            preflight_map_tuple_reader_charges = Hash(String, UInt64).new
            preflight_tuple_row_charges = Hash(String, UInt64).new
            preflight_variant_string_uint64_raw_bytes = Hash(String, UInt64).new
            preflight_variant_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_variant_bool_string_uint64_raw_bytes = Hash(String, UInt64).new
            preflight_variant_bool_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_dynamic_string_raw_bytes = Hash(String, UInt64).new
            preflight_dynamic_string_uint64_raw_bytes = Hash(String, UInt64).new
            preflight_dynamic_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_array_fixed_string_raw_bytes = Hash(String, UInt64).new
            preflight_array_bool_raw_bytes = Hash(String, UInt64).new
            preflight_array_nullable_bool_raw_bytes = Hash(String, UInt64).new
            preflight_map_string_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_array_map_string_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_array_map_string_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_array_map_numeric_payload_charge = Hash(String, {UInt64, UInt64}).new
            preflight_map_string_array_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_array_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_array_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_array_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_uint64_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_uint64_charge_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_uint64_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_string_payload_bytes = Hash(String, UInt64).new
            preflight_map_string_nullable_string_charge_bytes = Hash(String, UInt64).new
            preflight_numeric_map_payload_charge = Hash(String, {UInt64, UInt64}).new
            part.readers.each do |selected|
              if aggregate_count_plan = WideAggregateCountStoragePlan.for_type_name(selected.column_type)
                expected_charge = WideAggregateCountTableMaterializer.preflight(
                  mark_rows,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
                )
                preflight_aggregate_count_charges[selected.name] = expected_charge
                bytes = expected_charge
              elsif selected.column_type == "Dynamic"
                if selected.reader.dynamic_string_uint64_profile?
                  raw_bytes, charge_bytes = selected.reader.dynamic_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                  preflight_dynamic_string_uint64_raw_bytes[selected.name] = raw_bytes
                  preflight_dynamic_string_uint64_charge_bytes[selected.name] = charge_bytes
                  bytes = charge_bytes
                else
                  bytes = selected.reader.dynamic_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                  preflight_dynamic_string_raw_bytes[selected.name] = bytes
                end
              elsif GeometryColumnAdapter.type?(selected.column_type)
                charge = GeometryColumnAdapter.preflight_charge(
                  selected.reader,
                  selected.name,
                  mark_index,
                  mark_rows,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
                )
                preflight_geometry_charges[selected.name] = charge
                bytes = charge
              elsif GeoArrayColumnAdapter.type?(selected.column_type)
                charge = GeoArrayColumnAdapter.preflight_charge(
                  selected.reader, selected.name, mark_index, mark_rows,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
                )
                preflight_geo_array_charges[selected.name] = charge
                bytes = charge
              elsif PointColumnAdapter.type?(selected.column_type)
                charge = PointColumnAdapter.preflight_charge(
                  selected.reader,
                  selected.name,
                  mark_index,
                  (MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes)
                )
                preflight_point_charges[selected.name] = charge
                bytes = charge
              elsif QBitColumnAdapter.type?(selected.column_type)
                bytes = QBitColumnAdapter.preflight_charge(selected.reader, selected.name, mark_index)
                preflight_qbit_charges[selected.name] = bytes
              elsif selected.column_type == "Variant(String, UInt64)"
                raw_bytes, charge_bytes = selected.reader.variant_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_variant_string_uint64_raw_bytes[selected.name] = raw_bytes
                preflight_variant_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif selected.column_type == WideVariantBoolStringUInt64TypePlan::TYPE
                raw_bytes, charge_bytes = selected.reader.variant_bool_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_variant_bool_string_uint64_raw_bytes[selected.name] = raw_bytes
                preflight_variant_bool_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif selected.column_type == "Array(Map(String, UInt64))"
                preflight = selected.reader.array_map_string_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                payload_bytes = preflight[:payload_bytes]
                charge_bytes = preflight[:charge_bytes]
                preflight_array_map_string_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_array_map_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.array_map_uint64_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = array_map_numeric_preflight(selected, mark_index, value_type, false, false)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif value_type = WidePart.array_map_string_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = array_map_numeric_preflight(selected, mark_index, value_type, true, false)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif value_type = WidePart.array_map_uint64_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = array_map_numeric_preflight(selected, mark_index, value_type, false, true)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif value_type = WidePart.array_map_string_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = array_map_numeric_preflight(selected, mark_index, value_type, true, true)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_array_map_string_leaf_type?(selected.column_type)
                payload_bytes, charge_bytes = array_map_string_leaf_preflight(selected, mark_index)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_array_map_bool_leaf_type?(selected.column_type)
                payload_bytes, charge_bytes = array_map_bool_leaf_preflight(selected, mark_index)
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_array_map_array_leaf_type?(selected.column_type)
                preflight = selected.reader.array_map_array_leaf_mark_range_materialization_preflight(selected.name, mark_index, 1)
                payload_bytes = preflight[:payload_bytes]
                charge_bytes = preflight[:charge_bytes]
                preflight_array_map_numeric_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif plan = WideTypePlan.admitted(selected.column_type)
                bytes = case plan.shape
                        when WideTypePlan::Shape::ArrayArrayString
                          selected.reader.array_array_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayArrayNullableString
                          selected.reader.array_array_nullable_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleUInt64String
                          selected.reader.preflight_array_tuple_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleNullableUInt64String
                          selected.reader.preflight_array_tuple_nullable_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        when WideTypePlan::Shape::ArrayTupleUInt64UInt64
                          selected.reader.preflight_array_tuple_uint64_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                        else
                          raise UnsupportedFormatError.new("unsupported admitted Array(Tuple) plan")
                        end
                if plan.shape == WideTypePlan::Shape::ArrayArrayString
                  preflight_array_array_string_bytes[selected.name] = bytes
                elsif plan.shape == WideTypePlan::Shape::ArrayArrayNullableString
                  preflight_array_array_nullable_string_bytes[selected.name] = bytes
                else
                  preflight_array_tuple_bytes[selected.name] = bytes
                end
              elsif ArrayTupleColumnAdapter.generic_type?(selected.column_type)
                charge = ArrayTupleColumnAdapter.preflight_mark_charge(
                  selected.reader,
                  selected.name,
                  mark_index,
                  (MAX_MARK_MATERIALIZED_BYTES - preflight_string_bytes).to_u64
                )
                preflight_array_tuple_reader_charges[selected.name] = charge
                bytes = charge
              elsif MapTupleColumnAdapter.generic_type?(selected.column_type)
                charge = MapTupleColumnAdapter.preflight_mark_charge(
                  selected.reader,
                  selected.name,
                  mark_index,
                  mark_rows,
                  (MAX_MARK_MATERIALIZED_BYTES - preflight_string_bytes).to_u64
                )
                preflight_map_tuple_reader_charges[selected.name] = charge
                bytes = charge
              elsif plan = SimpleAggregateTextStoragePlan.for_type_name(selected.column_type)
                bytes = if plan.variable_string?
                          if plan.nullable?
                            selected.reader.nullable_simple_aggregate_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                          else
                            selected.reader.simple_aggregate_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                          end
                        elsif plan.nullable?
                          selected.reader.nullable_simple_aggregate_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        else
                          selected.reader.simple_aggregate_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        end
                preflight_simple_aggregate_text_bytes[selected.name] = bytes
              elsif selected.column_type == "String" || WidePart.supports_nullable_string_type?(selected.column_type)
                bytes = if selected.column_type == "String"
                          selected.reader.string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        else
                          selected.reader.nullable_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        end
              elsif selected.column_type == "LowCardinality(String)"
                bytes = selected.reader.low_cardinality_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.fixed_string_width(selected.column_type)
                bytes = selected.reader.fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.nullable_fixed_string_width(selected.column_type)
                bytes = selected.reader.nullable_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif width = WidePart.array_fixed_string_width(selected.column_type)
                raw_bytes = selected.reader.array_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_fixed_string_raw_bytes[selected.name] = raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, false)
              elsif width = WidePart.array_nullable_fixed_string_width(selected.column_type)
                raw_bytes = selected.reader.array_nullable_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_fixed_string_raw_bytes[selected.name] = raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, true)
              elsif WidePart.supports_array_bool_type?(selected.column_type)
                bytes = selected.reader.array_bool_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_bool_raw_bytes[selected.name] = bytes
              elsif WidePart.supports_array_nullable_bool_type?(selected.column_type)
                bytes = selected.reader.array_nullable_bool_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_bool_raw_bytes[selected.name] = bytes
              elsif WidePart.time_array_element_type(selected.column_type)
                bytes = selected.reader.array_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_time_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.temporal_array_element_type(selected.column_type)
                bytes = selected.reader.array_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_temporal_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_enum8_codes(selected.column_type)
                bytes = selected.reader.array_enum8_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_enum8_codes(selected.column_type)
                bytes = selected.reader.array_nullable_enum8_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_enum16_codes(selected.column_type)
                bytes = selected.reader.array_enum16_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_enum16_codes(selected.column_type)
                bytes = selected.reader.array_nullable_enum16_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_nullable_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_nullable_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.uuid_array_element_type(selected.column_type)
                bytes = selected.reader.array_uuid_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_uuid_bytes[selected.name] = bytes
              elsif WidePart.nullable_uuid_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_uuid_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_uuid_bytes[selected.name] = bytes
              elsif WidePart.ipv4_array_element_type(selected.column_type)
                bytes = selected.reader.array_ipv4_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_ipv4_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_ipv4_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.ipv6_array_element_type(selected.column_type)
                bytes = selected.reader.array_ipv6_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_ipv6_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_ipv6_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.numeric_array_element_type(selected.column_type)
                bytes = selected.reader.array_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.nullable_numeric_array_element_type(selected.column_type)
                bytes = selected.reader.array_nullable_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_nullable_numeric_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(Nullable(UInt64))"
                bytes = selected.reader.array_nullable_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(Array(UInt64))"
                bytes = selected.reader.array_array_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_uint64_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(Array(Nullable(UInt64)))"
                bytes = selected.reader.array_array_nullable_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_uint64_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_temporal_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_temporal_element_type(selected.column_type)
                bytes = selected.reader.array_array_temporal_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_time_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_time_element_type(selected.column_type)
                bytes = selected.reader.array_array_time_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_array_nullable_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal32_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal32_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal64_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal64_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal128_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal128_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_decimal256_scale(selected.column_type)
                bytes = selected.reader.array_array_decimal256_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_nullable_numeric_element_type(selected.column_type)
                bytes = selected.reader.array_array_nullable_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_nullable_numeric_bytes[selected.name] = bytes
              elsif WidePart.array_array_numeric_element_type(selected.column_type)
                bytes = selected.reader.array_array_numeric_mark_range_raw_bytes(selected.name, mark_index, 1)
                preflight_array_array_numeric_bytes[selected.name] = bytes
              elsif selected.column_type == "Array(String)"
                bytes = selected.reader.array_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(Nullable(String))"
                raw_bytes, charge_bytes = selected.reader.array_nullable_string_mark_range_preflight(selected.name, mark_index, 1)
                preflight_array_nullable_string_raw_bytes[selected.name] = raw_bytes
                preflight_array_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_tuple_uint64_string_type?(selected.column_type)
                bytes = selected.reader.tuple_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif TupleColumnAdapter.generic_type?(selected.column_type)
                charge = TupleColumnAdapter.preflight_mark_charge(
                  selected.reader,
                  selected.name,
                  mark_index,
                  mark_rows,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
                )
                preflight_tuple_row_charges[selected.name] = charge
                bytes = charge
              elsif WidePart.supports_map_uint64_string_type?(selected.column_type)
                bytes = selected.reader.map_uint64_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.supports_map_uint64_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, UInt64)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif value_type = WidePart.map_uint64_numeric_value_type(selected.column_type)
                if value_type == "UInt64"
                  next
                end
                payload_bytes, charge_bytes = numeric_map_preflight(selected, mark_index, value_type, false)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_uint64_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = nullable_numeric_map_preflight(selected, mark_index, value_type, false)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_array_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_array_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_array_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_uint64_array_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = numeric_map_array_preflight(selected, mark_index, value_type, false, true)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_array_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_array_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_array_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_array_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_array_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_array_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_array_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_array_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_uint64_array_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = numeric_map_array_preflight(selected, mark_index, value_type, false)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_array_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_array_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_array_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_array_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, UInt64)
                preflight_map_string_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_string_numeric_value_type(selected.column_type)
                if value_type == "UInt64"
                  next
                end
                payload_bytes, charge_bytes = numeric_map_preflight(selected, mark_index, value_type, true)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_string_array_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = numeric_map_array_preflight(selected, mark_index, value_type, true)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_string_array_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = numeric_map_array_preflight(selected, mark_index, value_type, true, true)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_string_array_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_array_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_array_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_array_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_nullable_uint64_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_nullable_uint64_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_nullable_uint64_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_nullable_uint64_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif value_type = WidePart.map_string_nullable_numeric_value_type(selected.column_type)
                payload_bytes, charge_bytes = nullable_numeric_map_preflight(selected, mark_index, value_type, true)
                preflight_numeric_map_payload_charge[selected.name] = {payload_bytes, charge_bytes}
                bytes = charge_bytes
              elsif WidePart.supports_map_uint64_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_uint64_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_uint64_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_uint64_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              elsif WidePart.supports_map_string_nullable_string_type?(selected.column_type)
                payload_bytes, charge_bytes = selected.reader.map_string_nullable_string_mark_range_materialization_preflight(selected.name, mark_index, 1)
                preflight_map_string_nullable_string_payload_bytes[selected.name] = payload_bytes
                preflight_map_string_nullable_string_charge_bytes[selected.name] = charge_bytes
                bytes = charge_bytes
              else
                next
              end
              if bytes > (MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes)
                raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit")
              end
              preflight_string_bytes += bytes
            end
            part.object_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
              bytes = ObjectColumnAdapter.preflight_owner(mark_rows, remaining_bytes)
              preflight_string_bytes += bytes
            end
            part.array_object_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
              bytes = ArrayObjectColumnAdapter.preflight_owner(
                selected.reader,
                mark_index.to_i32,
                mark_rows,
                remaining_bytes
              )
              preflight_string_bytes += bytes
            end
            part.recursive_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes
              bytes = RecursiveColumnAdapter.preflight_owner(
                selected.reader,
                selected.schema,
                mark_index.to_i32,
                mark_rows,
                remaining_bytes
              )
              preflight_string_bytes += bytes
            end

            numeric_values = Hash(String, WidePartNumericArray).new
            aggregate_count_values = Hash(String, Array(BinaryValue)).new
            string_values = Hash(String, Array(String)).new
            fixed_string_values = Hash(String, Array(String)).new
            nullable_values = Hash(String, WidePartNullableArray).new
            nullable_string_values = Hash(String, WidePartNullableStringArray).new
            nullable_fixed_string_values = Hash(String, WidePartNullableStringArray).new
            array_uint64_values = Hash(String, Array(Array(UInt64))).new
            array_nullable_uint64_values = Hash(String, Array(Array(UInt64?))).new
            array_string_values = Hash(String, Array(Array(String))).new
            array_nullable_string_values = Hash(String, WidePartArrayNullableStringArray).new
            array_array_uint64_values = Hash(String, Array(Array(Array(UInt64)))).new
            array_array_string_values = Hash(String, Array(Array(Array(String)))).new
            array_array_nullable_string_values = Hash(String, WidePartArrayArrayNullableStringArray).new
            array_array_nullable_uint64_values = Hash(String, Array(Array(Array(UInt64?)))).new
            array_array_numeric_values = Hash(String, WidePartArrayArrayNumericArray).new
            array_array_nullable_numeric_values = Hash(String, WidePartArrayArrayNullableNumericArray).new
            array_numeric_values = Hash(String, WidePartArrayNumericArray).new
            array_nullable_numeric_values = Hash(String, WidePartArrayNullableNumericArray).new
            array_bool_values = Hash(String, WidePartArrayBoolArray).new
            array_nullable_bool_values = Hash(String, WidePartArrayNullableBoolArray).new
            array_tuple_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64, String)))).new
            array_tuple_nullable_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64?, String)))).new
            array_tuple_uint64_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64)))).new
            variant_string_uint64_values = Hash(String, Array(VariantStringUInt64Value)).new
            variant_bool_string_uint64_values = Hash(String, Array(VariantBoolStringUInt64Value)).new
            tuple_string_values = Hash(String, Array(Tuple(UInt64, String))).new
            tuple_row_values = Hash(String, Array(WideTupleRow)).new
            generic_array_tuple_rows = Hash(String, Array(WideArrayTupleRow)).new
            generic_map_tuple_rows = Hash(String, Array(WideMapTupleRow)).new
            map_uint64_string_values = Hash(String, Array(Array(Tuple(UInt64, String)))).new
            map_uint64_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64)))).new
            map_string_uint64_values = Hash(String, Array(Array(Tuple(String, UInt64)))).new
            map_string_array_uint64_values = Hash(String, Array(Array(Tuple(String, Array(UInt64))))).new
            array_map_string_uint64_values = Hash(String, Array(Array(Array(Tuple(String, UInt64))))).new
            array_map_numeric_values = Hash(String, WidePartArrayMapNumericRowsBase).new
            map_string_array_nullable_uint64_values = Hash(String, Array(Array(Tuple(String, Array(UInt64?))))).new
            map_string_array_nullable_string_values = Hash(String, Array(Array(Tuple(String, Array(String?))))).new
            map_uint64_array_nullable_uint64_values = Hash(String, Array(Array(Tuple(UInt64, Array(UInt64?))))).new
            map_uint64_array_nullable_string_values = Hash(String, Array(Array(Tuple(UInt64, Array(String?))))).new
            map_uint64_array_uint64_values = Hash(String, Array(Array(Tuple(UInt64, Array(UInt64))))).new
            map_string_array_string_values = Hash(String, Array(Array(Tuple(String, Array(String))))).new
            map_uint64_array_string_values = Hash(String, Array(Array(Tuple(UInt64, Array(String))))).new
            map_string_string_values = Hash(String, Array(Array(Tuple(String, String)))).new
            map_uint64_nullable_uint64_values = Hash(String, Array(Array(Tuple(UInt64, UInt64?)))).new
            map_string_nullable_uint64_values = Hash(String, Array(Array(Tuple(String, UInt64?)))).new
            map_uint64_nullable_string_values = Hash(String, Array(Array(Tuple(UInt64, String?)))).new
            map_string_nullable_string_values = Hash(String, Array(Array(Tuple(String, String?)))).new
            numeric_map_values = Hash(String, WidePartNumericMapRowsBase).new
            qbit_values = Hash(String, Array(QBitValue)).new
            nullable_qbit_values = Hash(String, Array(QBitValue?)).new
            point_values = Hash(String, Array(WidePointValue)).new
            geo_array_rows = Hash(String, Array(WideGeoArrayRow)).new
            geometry_rows = Hash(String, Array(WideGeometryRow)).new
            object_documents = Hash(String, Array(ObjectDocument)).new
            array_object_documents = Hash(String, Array(Array(ObjectDocument))).new
            actual_string_bytes = 0_u64
            part.readers.each do |selected|
              if count_plan = WideAggregateCountStoragePlan.for_type_name(selected.column_type)
                expected_charge = preflight_aggregate_count_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected AggregateFunction(count) mark was not preflighted"))
                remaining_charge = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                values, charge = WideAggregateCountTableMaterializer.materialize(
                  selected.reader,
                  selected.name,
                  mark_index,
                  mark_rows,
                  count_plan.data_type,
                  expected_charge,
                  remaining_charge
                )
                actual_string_bytes += charge
                aggregate_count_values[selected.name] = values
                next
              elsif GeometryColumnAdapter.type?(selected.column_type)
                expected_charge = preflight_geometry_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Geometry mark was not preflighted"))
                values, charge = GeometryColumnAdapter.materialize_mark(
                  selected.reader,
                  selected.name,
                  selected.column_type,
                  mark_index,
                  mark_rows,
                  expected_charge,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                )
                actual_string_bytes += charge
                geometry_rows[selected.name] = values
                next
              elsif GeoArrayColumnAdapter.type?(selected.column_type)
                expected_charge = preflight_geo_array_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Geo Array mark was not preflighted"))
                values, charge = GeoArrayColumnAdapter.materialize_mark(
                  selected.reader, selected.name, selected.column_type, mark_index,
                  mark_rows, expected_charge,
                  MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                )
                actual_string_bytes += charge
                geo_array_rows[selected.name] = values
                next
              elsif PointColumnAdapter.type?(selected.column_type)
                expected_charge = preflight_point_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Point mark was not preflighted"))
                remaining_charge = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                values, observed_charge = PointColumnAdapter.materialize_mark(
                  selected.reader,
                  selected.name,
                  mark_index,
                  mark_rows,
                  expected_charge,
                  remaining_charge
                )
                if observed_charge > remaining_charge
                  raise CorruptPartError.new("selected Point mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += observed_charge
                point_values[selected.name] = values
                next
              elsif qbit_plan = QBitColumnType.for_type(selected.column_type)
                expected_charge = preflight_qbit_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected QBit mark was not preflighted"))
                exact_charge = qbit_plan.materialization_charge(mark_rows)
                raise CorruptPartError.new("selected QBit charge changed after preflight") unless expected_charge == exact_charge
                if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  raise CorruptPartError.new("selected QBit mark exceeds aggregate materialization limit")
                end
                if qbit_plan.nullable
                  values = QBitColumnAdapter.read_nullable(selected.reader, selected.name, mark_index)
                  raise CorruptPartError.new("selected Nullable(QBit) mark row count changed") unless values.size.to_u64 == mark_rows
                  nullable_qbit_values[selected.name] = values
                else
                  values = QBitColumnAdapter.read_non_nullable(selected.reader, selected.name, mark_index)
                  raise CorruptPartError.new("selected QBit mark row count changed") unless values.size.to_u64 == mark_rows
                  qbit_values[selected.name] = values
                end
                actual_string_bytes += expected_charge
                next
              elsif selected.column_type == "Variant(String, UInt64)"
                values = selected.reader.read_variant_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Variant mark row count changed") unless values.size.to_u64 == mark_rows
                expected_raw = preflight_variant_string_uint64_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant mark was not preflighted"))
                expected_charge = preflight_variant_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant charge was not preflighted"))
                decoded_raw = 0_u64
                values.each do |value|
                  next unless value.is_a?(String)
                  string_bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected Variant String bytes changed after preflight") if string_bytes > expected_raw - decoded_raw
                  decoded_raw += string_bytes
                end
                raise CorruptPartError.new("selected Variant String bytes differ from preflight") unless decoded_raw == expected_raw
                row_charge = WidePart::VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
                raise CorruptPartError.new("selected Variant charge changed after preflight") unless mark_rows <= (UInt64::MAX - decoded_raw) // row_charge && decoded_raw + mark_rows * row_charge == expected_charge
                raise CorruptPartError.new("selected Variant mark exceeds aggregate materialization limit") if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += expected_charge
                variant_string_uint64_values[selected.name] = values
                next
              elsif selected.column_type == WideVariantBoolStringUInt64TypePlan::TYPE
                values = selected.reader.read_variant_bool_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Variant mark row count changed") unless values.size.to_u64 == mark_rows
                expected_raw = preflight_variant_bool_string_uint64_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant mark was not preflighted"))
                expected_charge = preflight_variant_bool_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Variant charge was not preflighted"))
                decoded_raw = 0_u64
                values.each do |value|
                  next unless value.is_a?(String)
                  string_bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected Variant String bytes changed after preflight") if decoded_raw > expected_raw || string_bytes > expected_raw - decoded_raw
                  decoded_raw += string_bytes
                end
                raise CorruptPartError.new("selected Variant String bytes differ from preflight") unless decoded_raw == expected_raw
                row_charge = WidePart::VARIANT_BOOL_STRING_UINT64_ROW_ACCOUNTING_BYTES
                raise CorruptPartError.new("selected Variant charge changed after preflight") unless mark_rows <= (UInt64::MAX - decoded_raw) // row_charge && decoded_raw + mark_rows * row_charge == expected_charge
                raise CorruptPartError.new("selected Variant mark exceeds aggregate materialization limit") if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += expected_charge
                variant_bool_string_uint64_values[selected.name] = values
                next
              elsif WidePart.array_enum8_codes(selected.column_type)
                values = selected.reader.read_array_enum8_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Enum8 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Enum8 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements
                raise CorruptPartError.new("selected Enum8 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Enum8 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_enum8_codes(selected.column_type)
                values = selected.reader.read_array_nullable_enum8_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Enum8 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Enum8 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int8")
                raise CorruptPartError.new("selected nullable Enum8 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Enum8 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_enum16_codes(selected.column_type)
                values = selected.reader.read_array_enum16_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Enum16 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Enum16 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 2_u64
                raise CorruptPartError.new("selected Enum16 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Enum16 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_enum16_codes(selected.column_type)
                values = selected.reader.read_array_nullable_enum16_codes_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Enum16 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Enum16 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int16")
                raise CorruptPartError.new("selected nullable Enum16 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Enum16 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_decimal32_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal32 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal32 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Decimal32 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal32 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal32_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal32_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal32 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal32 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected nullable Decimal32 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal32 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_decimal64_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal64 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 8_u64
                raise CorruptPartError.new("selected Decimal64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal64_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal64_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal64 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected nullable Decimal64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_decimal128_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal128 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal128 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Decimal128 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal128 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal128_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal128_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal128 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal128 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int128")
                raise CorruptPartError.new("selected nullable Decimal128 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal128 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              elsif WidePart.array_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_decimal256_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Decimal256 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal256 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 32_u64
                raise CorruptPartError.new("selected Decimal256 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal256 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                next
              elsif WidePart.array_nullable_decimal256_scale(selected.column_type)
                values = selected.reader.read_array_nullable_decimal256_raw_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected nullable Decimal256 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal256 Array mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Decimal256")
                raise CorruptPartError.new("selected nullable Decimal256 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal256 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                next
              end

              if plan = WideTypePlan.admitted(selected.column_type)
                case plan.shape
                when WideTypePlan::Shape::ArrayArrayString
                  values = selected.reader.read_array_array_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Array(String)) mark row count changed") unless values.size.to_u64 == mark_rows
                  preflight_bytes = preflight_array_array_string_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(String)) mark was not preflighted"))
                  decoded_bytes = array_array_string_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Array(String)) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_array_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayArrayNullableString
                  values = selected.reader.read_array_array_nullable_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark row count changed") unless values.size.to_u64 == mark_rows
                  preflight_bytes = preflight_array_array_nullable_string_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(String))) mark was not preflighted"))
                  decoded_bytes = array_array_nullable_string_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) decoded bytes exceed preflight") if decoded_bytes > preflight_bytes
                  raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit") if preflight_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += preflight_bytes
                  array_array_nullable_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleUInt64String
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_uint64_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_materialized_bytes(values, 16_u64)
                  raise CorruptPartError.new("selected Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_uint64_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleNullableUInt64String
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_nullable_uint64_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected nullable Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_materialized_bytes(values, 17_u64)
                  raise CorruptPartError.new("selected nullable Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected nullable Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_nullable_uint64_string_values[selected.name] = values
                when WideTypePlan::Shape::ArrayTupleUInt64UInt64
                  preflight_bytes = preflight_array_tuple_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                  values = selected.reader.read_array_tuple_uint64_uint64_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Array(Tuple) mark row count changed") unless values.size.to_u64 == mark_rows
                  decoded_bytes = array_tuple_uint64_uint64_materialized_bytes(values)
                  raise CorruptPartError.new("selected Array(Tuple) decoded bytes differ from preflight") unless decoded_bytes == preflight_bytes
                  raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit") if decoded_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += decoded_bytes
                  array_tuple_uint64_uint64_values[selected.name] = values
                end
                next
              end

              if TupleColumnAdapter.generic_type?(selected.column_type)
                expected_charge = preflight_tuple_row_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Tuple mark was not preflighted"))
                remaining_charge = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                rows, observed_charge = TupleColumnAdapter.materialize_mark(
                  selected.reader,
                  selected.name,
                  selected.column_type,
                  mark_index,
                  mark_rows,
                  expected_charge,
                  remaining_charge
                )
                if observed_charge > remaining_charge
                  raise CorruptPartError.new("selected Tuple mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += observed_charge
                tuple_row_values[selected.name] = rows
                next
              end

              if ArrayTupleColumnAdapter.generic_type?(selected.column_type)
                expected_charge = preflight_array_tuple_reader_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Array(Tuple) mark was not preflighted"))
                remaining_charge = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                values, observed_charge = ArrayTupleColumnAdapter.materialize_mark(
                  selected.reader,
                  selected.name,
                  selected.column_type,
                  mark_index,
                  mark_rows,
                  expected_charge,
                  remaining_charge
                )
                if observed_charge > remaining_charge
                  raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += observed_charge
                generic_array_tuple_rows[selected.name] = values
                next
              end

              if MapTupleColumnAdapter.generic_type?(selected.column_type)
                expected_charge = preflight_map_tuple_reader_charges[selected.name]? ||
                                  raise(CorruptPartError.new("selected Map(Tuple) mark was not preflighted"))
                remaining_charge = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                values, observed_charge = MapTupleColumnAdapter.materialize_mark(
                  selected.reader,
                  selected.name,
                  selected.column_type,
                  mark_index,
                  mark_rows,
                  expected_charge,
                  remaining_charge
                )
                if observed_charge > remaining_charge
                  raise CorruptPartError.new("selected Map(Tuple) mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += observed_charge
                generic_map_tuple_rows[selected.name] = values
                next
              end

              case selected.column_type
              when "Array(UUID)"
                values = selected.reader.read_array_uuids_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(UUID) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_uuid_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(UUID) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Array(UUID) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(UUID) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(UUID))"
                values = selected.reader.read_array_nullable_uuids_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(UUID)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_uuid_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(UUID)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 17_u64
                raise CorruptPartError.new("selected Array(Nullable(UUID)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(UUID)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(IPv4)"
                values = selected.reader.read_array_ipv4s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(IPv4) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(IPv4) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Array(IPv4) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(IPv4) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(IPv4))"
                values = selected.reader.read_array_nullable_ipv4s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(IPv4)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 5_u64
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(IPv4)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(IPv6)"
                values = selected.reader.read_array_ipv6s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(IPv6) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(IPv6) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 16_u64
                raise CorruptPartError.new("selected Array(IPv6) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(IPv6) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Nullable(IPv6))"
                values = selected.reader.read_array_nullable_ipv6s_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(IPv6)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 17_u64
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(IPv6)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(Date)", "Array(Date32)", "Array(DateTime)"
                element_type = WidePart.temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported temporal Array type"))
                values = read_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = elements * WidePart.array_numeric_payload_width(physical_type).to_u64
                raise CorruptPartError.new("selected temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("Array(DateTime('")
                element_type = WidePart.temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported temporal Array type"))
                values = read_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = elements * WidePart.array_numeric_payload_width(physical_type).to_u64
                raise CorruptPartError.new("selected temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when "Array(Time)"
                values = selected.reader.read_array_time_seconds_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Time Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 4_u64
                raise CorruptPartError.new("selected Time Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("Array(Time64(")
                raise UnsupportedFormatError.new("unsupported exact Time64 Array type") unless WidePart.array_time64_scale(selected.column_type)
                values = selected.reader.read_array_time64_ticks_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Time64 Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time64 Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 8_u64
                raise CorruptPartError.new("selected Time64 Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time64 Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("Array(DateTime64(")
                element_type = WidePart.temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported temporal Array type"))
                values = read_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal Array mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = elements * WidePart.array_numeric_payload_width(physical_type).to_u64
                raise CorruptPartError.new("selected temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
              when .starts_with?("SimpleAggregateFunction(")
                if plan = SimpleAggregateTextStoragePlan.for_type_name(selected.column_type)
                  expected_bytes = preflight_simple_aggregate_text_bytes[selected.name]? ||
                                   raise(CorruptPartError.new("selected SimpleAggregateFunction text mark was not preflighted"))
                  if plan.variable_string?
                    values, bytes = selected.reader.read_simple_aggregate_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                    raise CorruptPartError.new("selected SimpleAggregateFunction(String) mark row count changed") unless values.size.to_u64 == mark_rows
                    raise CorruptPartError.new("selected SimpleAggregateFunction(String) decoded bytes differ from preflight") unless bytes == expected_bytes
                    raise CorruptPartError.new("selected SimpleAggregateFunction(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                    actual_string_bytes += bytes
                    string_values[selected.name] = values
                  else
                    width = plan.fixed_string_width || raise(UnsupportedFormatError.new("unsupported SimpleAggregateFunction text storage"))
                    values = selected.reader.read_simple_aggregate_fixed_string_mark_range(selected.name, mark_index, 1)
                    raise CorruptPartError.new("selected SimpleAggregateFunction(FixedString) mark row count changed") unless values.size.to_u64 == mark_rows
                    bytes = values.size.to_u64 * width.to_u64
                    raise CorruptPartError.new("selected SimpleAggregateFunction(FixedString) decoded bytes differ from preflight") unless bytes == expected_bytes
                    raise CorruptPartError.new("selected SimpleAggregateFunction(FixedString) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                    actual_string_bytes += bytes
                    fixed_string_values[selected.name] = values
                  end
                else
                  values = read_numeric_values(selected, mark_index)
                  raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
                  numeric_values[selected.name] = values
                end
              when .starts_with?("Nullable(SimpleAggregateFunction(")
                if plan = SimpleAggregateTextStoragePlan.for_type_name(selected.column_type)
                  expected_bytes = preflight_simple_aggregate_text_bytes[selected.name]? ||
                                   raise(CorruptPartError.new("selected Nullable SimpleAggregateFunction text mark was not preflighted"))
                  if plan.variable_string?
                    values, bytes = selected.reader.read_nullable_simple_aggregate_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(String) mark row count changed") unless values.size.to_u64 == mark_rows
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(String) decoded bytes differ from preflight") unless bytes == expected_bytes
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                    actual_string_bytes += bytes
                    nullable_string_values[selected.name] = values
                  else
                    width = plan.fixed_string_width || raise(UnsupportedFormatError.new("unsupported Nullable SimpleAggregateFunction text storage"))
                    values = selected.reader.read_nullable_simple_aggregate_fixed_string_mark_range(selected.name, mark_index, 1)
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(FixedString) mark row count changed") unless values.size.to_u64 == mark_rows
                    # BASIC Nullable(FixedString(N)) stores one N-byte nested
                    # slot for every row, including rows visible as NULL.
                    bytes = values.size.to_u64 * width.to_u64
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(FixedString) decoded bytes differ from preflight") unless bytes == expected_bytes
                    raise CorruptPartError.new("selected Nullable SimpleAggregateFunction(FixedString) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                    actual_string_bytes += bytes
                    nullable_fixed_string_values[selected.name] = values
                  end
                else
                  values = read_nullable_values(selected, mark_index)
                  raise CorruptPartError.new("selected Nullable column mark row count changed") unless nullable_array_size(values).to_u64 == mark_rows
                  nullable_values[selected.name] = values
                end
              when "String"
                values = selected.reader.read_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected String mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |value|
                  bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                string_values[selected.name] = values
              when "Dynamic"
                if selected.reader.dynamic_string_uint64_profile?
                  values = selected.reader.read_dynamic_string_uint64_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Dynamic mark row count changed") unless values.size.to_u64 == mark_rows
                  expected_raw = preflight_dynamic_string_uint64_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected mixed Dynamic mark was not preflighted"))
                  expected_charge = preflight_dynamic_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected mixed Dynamic charge was not preflighted"))
                  decoded_raw = 0_u64
                  values.each do |value|
                    next unless string_value = value.as?(String)
                    string_bytes = string_value.bytesize.to_u64
                    if decoded_raw > expected_raw || string_bytes > expected_raw - decoded_raw
                      raise CorruptPartError.new("selected mixed Dynamic String bytes changed after preflight")
                    end
                    decoded_raw += string_bytes
                  end
                  raise CorruptPartError.new("selected mixed Dynamic String bytes differ from preflight") unless decoded_raw == expected_raw
                  row_charge = WidePart::VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
                  unless mark_rows <= (UInt64::MAX - decoded_raw) // row_charge && decoded_raw + mark_rows * row_charge == expected_charge
                    raise CorruptPartError.new("selected mixed Dynamic charge changed after preflight")
                  end
                  raise CorruptPartError.new("selected mixed Dynamic mark exceeds aggregate materialization limit") if expected_charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += expected_charge
                  variant_string_uint64_values[selected.name] = values
                else
                  values = selected.reader.read_dynamic_string_mark_range(selected.name, mark_index, 1)
                  raise CorruptPartError.new("selected Dynamic mark row count changed") unless values.size.to_u64 == mark_rows
                  bytes = values.sum(&.bytesize).to_u64
                  preflight_bytes = preflight_dynamic_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Dynamic mark was not preflighted"))
                  raise CorruptPartError.new("selected Dynamic decoded bytes differ from preflight") unless bytes == preflight_bytes
                  raise CorruptPartError.new("selected Dynamic mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                  string_values[selected.name] = values
                end
              when "LowCardinality(String)"
                values = selected.reader.read_low_cardinality_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected LowCardinality(String) mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |value|
                  bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected LowCardinality(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                string_values[selected.name] = values
              when "Nullable(String)"
                values, bytes = selected.reader.read_nullable_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Nullable(String) mark row count changed") unless values.size.to_u64 == mark_rows
                raise CorruptPartError.new("selected Nullable(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                nullable_string_values[selected.name] = values
              when .starts_with?("FixedString(")
                values = selected.reader.read_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected FixedString mark row count changed") unless values.size.to_u64 == mark_rows
                width = WidePart.fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact FixedString type"))
                bytes = values.size.to_u64 * width.to_u64
                raise CorruptPartError.new("selected FixedString mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                fixed_string_values[selected.name] = values
              when .starts_with?("Nullable(FixedString(")
                width = WidePart.nullable_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Nullable(FixedString) type"))
                values = selected.reader.read_nullable_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Nullable(FixedString) mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.size.to_u64 * width.to_u64
                raise CorruptPartError.new("selected Nullable(FixedString) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                nullable_fixed_string_values[selected.name] = values
              when "Array(UInt8)", "Array(UInt16)", "Array(UInt32)", "Array(UInt64)",
                   "Array(Int8)", "Array(Int16)", "Array(Int32)", "Array(Int64)",
                   "Array(Float32)", "Array(Float64)",
                   "Array(Int128)", "Array(UInt128)", "Array(Int256)", "Array(UInt256)",
                   "Array(BFloat16)"
                element_type = WidePart.numeric_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array numeric type"))
                values = read_array_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array numeric mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array numeric mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * WidePart.array_numeric_payload_width(element_type).to_u64
                raise CorruptPartError.new("selected Array numeric decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array numeric mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_numeric_values[selected.name] = values
                array_uint64_values[selected.name] = values.as(Array(Array(UInt64))) if selected.column_type == "Array(UInt64)"
              when "Array(Bool)"
                values = selected.reader.read_array_bool_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Bool) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_bool_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Bool) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                raise CorruptPartError.new("selected Array(Bool) decoded bytes differ from preflight") unless elements == preflight_bytes
                raise CorruptPartError.new("selected Array(Bool) mark exceeds aggregate materialization limit") if elements > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += elements
                array_bool_values[selected.name] = values
              when "Array(Nullable(String))"
                values, raw_bytes = selected.reader.read_array_nullable_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(String)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_nullable_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(String)) mark was not preflighted"))
                raise CorruptPartError.new("selected Array(Nullable(String)) decoded raw bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                visible_bytes, materialized_bytes = array_nullable_string_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Nullable(String)) visible bytes exceed preflight raw bytes") if visible_bytes > raw_bytes
                preflight_charge_bytes = preflight_array_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(String)) charge was not preflighted"))
                raise CorruptPartError.new("selected Array(Nullable(String)) decoded charge exceeds preflight") if materialized_bytes > preflight_charge_bytes
                raise CorruptPartError.new("selected Array(Nullable(String)) mark exceeds aggregate materialization limit") if materialized_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += materialized_bytes
                array_nullable_string_values[selected.name] = values
              when .starts_with?("Array(Nullable(FixedString(")
                width = WidePart.array_nullable_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Array(Nullable(FixedString(N))) type"))
                values = selected.reader.read_array_nullable_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_fixed_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark was not preflighted"))
                elements = checked_array_fixed_string_elements(values, width)
                raw_bytes = elements * (width.to_u64 + 1_u64)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) decoded bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, true)
                raise CorruptPartError.new("selected Array(Nullable(FixedString(N))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_string_values[selected.name] = values
              when "Array(Nullable(Bool))"
                values = selected.reader.read_array_nullable_bool_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Bool)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_bool_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Bool)) mark was not preflighted"))
                elements = values.sum(&.size).to_u64
                bytes = elements * 2_u64
                raise CorruptPartError.new("selected Array(Nullable(Bool)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Bool)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_bool_values[selected.name] = values
              when "Array(Nullable(Date))", "Array(Nullable(Date32))", "Array(Nullable(DateTime))"
                element_type = WidePart.nullable_temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array type"))
                values = read_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal Array mark was not preflighted"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(DateTime('")
                element_type = WidePart.nullable_temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array type"))
                values = read_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal Array mark was not preflighted"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when "Array(Nullable(Time))"
                values = selected.reader.read_array_nullable_time_seconds_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Time)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Time)) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int32")
                raise CorruptPartError.new("selected Array(Nullable(Time)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Time)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(Time64(")
                raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Time64(p))) type") unless WidePart.nullable_array_time64_scale(selected.column_type)
                values = selected.reader.read_array_nullable_time64_ticks_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(Time64(p))) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, "Int64")
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(Time64(p))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(DateTime64(")
                element_type = WidePart.nullable_temporal_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array type"))
                values = read_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal Array mark was not preflighted"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                bytes = array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Nullable(")
                element_type = WidePart.nullable_numeric_array_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array nullable numeric type"))
                values = read_array_nullable_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Nullable(T)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Nullable(T)) mark was not preflighted"))
                bytes = array_nullable_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Nullable(T)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Nullable(T)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_numeric_values[selected.name] = values
                array_nullable_uint64_values[selected.name] = values.as(Array(Array(UInt64?))) if element_type == "UInt64"
              when "Array(Nullable(UInt64))"
                values = selected.reader.read_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark row count changed") unless values.size.to_u64 == mark_rows
                elements = 0_u64
                values.each do |row|
                  row_elements = row.size.to_u64
                  if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
                    raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark element count exceeds materialization limit")
                  end
                  elements += row_elements
                end
                bytes = elements * 9_u64
                raise CorruptPartError.new("selected Array(Nullable(UInt64)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_nullable_uint64_values[selected.name] = values
              when "Array(Array(UInt64))"
                values = selected.reader.read_array_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Array(UInt64)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_uint64_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(UInt64)) mark was not preflighted"))
                bytes = array_array_uint64_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Array(UInt64)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(UInt64)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_uint64_values[selected.name] = values
                array_array_numeric_values[selected.name] = values.as(WidePartArrayArrayNumericArray)
              when "Array(Array(Nullable(UInt64)))"
                values = selected.reader.read_array_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_uint64_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark was not preflighted"))
                bytes = array_array_nullable_uint64_materialized_bytes(values)
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_uint64_values[selected.name] = values
                array_array_nullable_numeric_values[selected.name] = values.as(WidePartArrayArrayNullableNumericArray)
              when .starts_with?("Array(Array(Nullable(Time")
                element_type = WidePart.array_array_nullable_time_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested nullable Time declaration"))
                physical_type = WidePart.time_array_physical_type(element_type).not_nil!
                values = read_array_array_nullable_time_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable Time nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Time nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable Time nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Time nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Time")
                element_type = WidePart.array_array_time_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested Time declaration"))
                physical_type = WidePart.time_array_physical_type(element_type).not_nil!
                values = read_array_array_time_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Time nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Time nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected Time nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Time nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Date")
                element_type = WidePart.array_array_nullable_temporal_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested nullable temporal declaration"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                values = read_array_array_nullable_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected nullable temporal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable temporal nested Array mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected nullable temporal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable temporal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Date")
                element_type = WidePart.array_array_temporal_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested temporal declaration"))
                physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
                values = read_array_array_temporal_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected temporal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected temporal nested Array mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, physical_type)
                raise CorruptPartError.new("selected temporal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected temporal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(Decimal(")
                descriptor = DecimalColumnType.parse(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested nullable Decimal declaration"))
                raise UnsupportedFormatError.new("unsupported nested nullable Decimal declaration") unless descriptor.shape == DecimalColumnShape::ArrayArrayNullable
                values = case descriptor.storage_width
                         when 4
                           selected.reader.read_array_array_nullable_decimal32_mark_range(selected.name, mark_index, 1)
                         when 8
                           selected.reader.read_array_array_nullable_decimal64_mark_range(selected.name, mark_index, 1)
                         when 16
                           selected.reader.read_array_array_nullable_decimal128_mark_range(selected.name, mark_index, 1)
                         when 32
                           selected.reader.read_array_array_nullable_decimal256_mark_range(selected.name, mark_index, 1)
                         else
                           raise UnsupportedFormatError.new("unsupported nested nullable Decimal width")
                         end
                raise CorruptPartError.new("selected nullable Decimal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected nullable Decimal nested Array mark was not preflighted"))
                element_type = case descriptor.storage_width
                               when  4 then "Int32"
                               when  8 then "Int64"
                               when 16 then "Int128"
                               when 32 then "Decimal256"
                               else         raise UnsupportedFormatError.new("unsupported nested nullable Decimal width")
                               end
                bytes = array_array_nullable_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected nullable Decimal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected nullable Decimal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Decimal(")
                descriptor = DecimalColumnType.parse(selected.column_type) || raise(UnsupportedFormatError.new("unsupported nested Decimal declaration"))
                raise UnsupportedFormatError.new("unsupported nested Decimal declaration") unless descriptor.shape == DecimalColumnShape::ArrayArray
                values = case descriptor.storage_width
                         when 4
                           selected.reader.read_array_array_decimal32_mark_range(selected.name, mark_index, 1)
                         when 8
                           selected.reader.read_array_array_decimal64_mark_range(selected.name, mark_index, 1)
                         when 16
                           selected.reader.read_array_array_decimal128_mark_range(selected.name, mark_index, 1)
                         when 32
                           selected.reader.read_array_array_decimal256_mark_range(selected.name, mark_index, 1)
                         else
                           raise UnsupportedFormatError.new("unsupported nested Decimal width")
                         end
                raise CorruptPartError.new("selected Decimal nested Array mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Decimal nested Array mark was not preflighted"))
                element_type = case descriptor.storage_width
                               when  4 then "Int32"
                               when  8 then "Int64"
                               when 16 then "Int128"
                               when 32 then "Decimal256"
                               else         raise UnsupportedFormatError.new("unsupported nested Decimal width")
                               end
                bytes = array_array_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Decimal nested Array decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Decimal nested Array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(Nullable(")
                element_type = WidePart.array_array_nullable_numeric_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric type"))
                values = read_array_array_nullable_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_nullable_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(Nullable(T))) mark was not preflighted"))
                bytes = array_array_nullable_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_nullable_numeric_values[selected.name] = values
              when .starts_with?("Array(Array(")
                element_type = WidePart.array_array_numeric_element_type(selected.column_type) || raise(UnsupportedFormatError.new("unsupported Array(Array(T)) numeric type"))
                values = read_array_array_numeric_values(selected.reader, selected.name, mark_index, element_type)
                raise CorruptPartError.new("selected Array(Array(T)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_bytes = preflight_array_array_numeric_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Array(T)) mark was not preflighted"))
                bytes = array_array_numeric_materialized_bytes(values, element_type)
                raise CorruptPartError.new("selected Array(Array(T)) decoded bytes differ from preflight") unless bytes == preflight_bytes
                raise CorruptPartError.new("selected Array(Array(T)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_array_numeric_values[selected.name] = values
              when "Array(String)"
                values = selected.reader.read_array_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(String) mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.sum { |row| row.sum(&.bytesize) }.to_u64
                raise CorruptPartError.new("selected array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_string_values[selected.name] = values
              when .starts_with?("Array(FixedString(")
                width = WidePart.array_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Array(FixedString(N)) type"))
                values = selected.reader.read_array_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(FixedString(N)) mark row count changed") unless values.size.to_u64 == mark_rows
                preflight_raw_bytes = preflight_array_fixed_string_raw_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(FixedString(N)) mark was not preflighted"))
                elements = checked_array_fixed_string_elements(values, width)
                raw_bytes = elements * width.to_u64
                raise CorruptPartError.new("selected Array(FixedString(N)) decoded bytes differ from preflight") unless raw_bytes == preflight_raw_bytes
                bytes = array_fixed_string_charge_bytes(raw_bytes, width, mark_rows, false)
                raise CorruptPartError.new("selected Array(FixedString(N)) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_string_values[selected.name] = values
              when "Tuple(a UInt64, b String)"
                values = selected.reader.read_tuple_uint64_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Tuple mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |_number, string_value|
                  bytes = string_value.bytesize.to_u64
                  raise CorruptPartError.new("selected Tuple mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                tuple_string_values[selected.name] = values
              when "Map(UInt64, String)"
                values = selected.reader.read_map_uint64_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.sum { |row| row.sum { |_key, value| value.bytesize } }.to_u64
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_uint64_string_values[selected.name] = values
              when "Map(UInt64, UInt64)"
                values = selected.reader.read_map_uint64_uint64_mark_range(selected.name, mark_index, 1)
                charge_bytes = verify_numeric_map_materialization(
                  selected,
                  WidePartNumericMapRows(UInt64, UInt64).new(values),
                  mark_rows,
                  preflight_numeric_map_payload_charge
                )
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_uint64_values[selected.name] = values
              when "Map(UInt64, UInt8)", "Map(UInt64, UInt16)", "Map(UInt64, UInt32)",
                   "Map(UInt64, Int8)", "Map(UInt64, Int16)", "Map(UInt64, Int32)", "Map(UInt64, Int64)",
                   "Map(UInt64, Float32)", "Map(UInt64, Float64)",
                   "Map(String, UInt8)", "Map(String, UInt16)", "Map(String, UInt32)",
                   "Map(String, Int8)", "Map(String, Int16)", "Map(String, Int32)", "Map(String, Int64)",
                   "Map(String, Float32)", "Map(String, Float64)",
                   "Map(UInt64, Nullable(UInt8))", "Map(UInt64, Nullable(UInt16))", "Map(UInt64, Nullable(UInt32))",
                   "Map(UInt64, Nullable(Int8))", "Map(UInt64, Nullable(Int16))", "Map(UInt64, Nullable(Int32))", "Map(UInt64, Nullable(Int64))",
                   "Map(UInt64, Nullable(Float32))", "Map(UInt64, Nullable(Float64))",
                   "Map(String, Nullable(UInt8))", "Map(String, Nullable(UInt16))", "Map(String, Nullable(UInt32))",
                   "Map(String, Nullable(Int8))", "Map(String, Nullable(Int16))", "Map(String, Nullable(Int32))", "Map(String, Nullable(Int64))",
                   "Map(String, Nullable(Float32))", "Map(String, Nullable(Float64))"
                values = read_numeric_map_rows(selected, mark_index)
                charge_bytes = verify_numeric_map_materialization(selected, values, mark_rows, preflight_numeric_map_payload_charge)
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                numeric_map_values[selected.name] = values
              when "Map(UInt64, Nullable(UInt64))"
                values = selected.reader.read_map_uint64_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                end
                if entries > UInt64::MAX // 17_u64
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = entries * 17_u64
                expected_payload_bytes = preflight_map_uint64_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_nullable_uint64_values[selected.name] = values
              when "Map(String, UInt64)"
                values = selected.reader.read_map_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, _value|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                  end
                end
                value_bytes = entries * 8_u64
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(
                  mark_rows, entries, payload_bytes, WidePart::NUMERIC_MAP_ROW_ACCOUNTING_BYTES
                )
                expected_charge_bytes = preflight_map_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                bytes = charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_string_uint64_values[selected.name] = values
              when "Array(Map(String, UInt64))"
                values = selected.reader.read_array_map_string_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(Map) mark row count changed") unless values.size.to_u64 == mark_rows
                maps = 0_u64
                entries = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  raise CorruptPartError.new("selected Array(Map) map count exceeds materialization limit") if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - maps
                  maps += row.size.to_u64
                  row.each do |map|
                    raise CorruptPartError.new("selected Array(Map) entry count exceeds materialization limit") if map.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    entries += map.size.to_u64
                    map.each do |key, _value|
                      bytes = key.bytesize.to_u64
                      raise CorruptPartError.new("selected Array(Map) key bytes exceed materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                      key_bytes += bytes
                    end
                  end
                end
                raise CorruptPartError.new("selected Array(Map) value bytes overflow") if entries > UInt64::MAX // 8_u64
                value_bytes = entries * 8_u64
                raise CorruptPartError.new("selected Array(Map) value bytes exceed materialization limit") if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                raise CorruptPartError.new("selected Array(Map) payload bytes overflow") if value_bytes > UInt64::MAX - key_bytes
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_array_map_string_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Map) payload was not preflighted"))
                raise CorruptPartError.new("selected Array(Map) payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = preflight_array_map_string_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Array(Map) charge was not preflighted"))
                row_width = WidePart::ARRAY_MAP_ROW_ACCOUNTING_BYTES
                map_width = WidePart::ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES
                entry_width = WidePart::ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
                if mark_rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width || entries > UInt64::MAX // entry_width
                  raise CorruptPartError.new("selected Array(Map) materialization charge overflows")
                end
                row_bytes = mark_rows * row_width
                map_bytes = maps * map_width
                entry_bytes = entries * entry_width
                if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
                   payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes
                  raise CorruptPartError.new("selected Array(Map) materialization charge overflows")
                end
                actual_charge_bytes = row_bytes + map_bytes + entry_bytes + payload_bytes
                raise CorruptPartError.new("selected Array(Map) charge differs from preflight") unless actual_charge_bytes == charge_bytes
                raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                array_map_string_uint64_values[selected.name] = values
              when "Array(Map(UInt64, Bool))", "Array(Map(String, Bool))",
                   "Array(Map(UInt64, Nullable(Bool)))", "Array(Map(String, Nullable(Bool)))"
                values = read_array_map_bool_leaf_rows(selected, mark_index)
                charge_bytes = verify_array_map_numeric_materialization(
                  selected, values, mark_rows, preflight_array_map_numeric_payload_charge
                )
                raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                array_map_numeric_values[selected.name] = values
              when "Array(Map(UInt64, String))", "Array(Map(String, String))",
                   "Array(Map(UInt64, Nullable(String)))", "Array(Map(String, Nullable(String)))"
                values = read_array_map_string_leaf_rows(selected, mark_index)
                charge_bytes = verify_array_map_numeric_materialization(
                  selected, values, mark_rows, preflight_array_map_numeric_payload_charge
                )
                raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                array_map_numeric_values[selected.name] = values
              when "Array(Map(UInt64, Array(UInt64)))", "Array(Map(UInt64, Array(String)))",
                   "Array(Map(String, Array(UInt64)))", "Array(Map(String, Array(String)))"
                values = read_array_map_array_leaf_rows(selected, mark_index)
                charge_bytes = verify_array_map_array_leaf_materialization(
                  selected, values, mark_rows, preflight_array_map_numeric_payload_charge
                )
                raise CorruptPartError.new("selected W84 Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                array_map_numeric_values[selected.name] = values
              when .starts_with?("Array(Map(")
                if WidePart.supports_array_map_array_leaf_type?(selected.column_type)
                  values = read_array_map_array_leaf_rows(selected, mark_index)
                  charge_bytes = verify_array_map_array_leaf_materialization(
                    selected, values, mark_rows, preflight_array_map_numeric_payload_charge
                  )
                  raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += charge_bytes
                  array_map_numeric_values[selected.name] = values
                else
                  raise UnsupportedFormatError.new("unsupported exact Array(Map) numeric type") unless WidePart.supports_array_map_numeric_type?(selected.column_type)
                  values = read_array_map_numeric_rows(selected, mark_index)
                  charge_bytes = verify_array_map_numeric_materialization(
                    selected, values, mark_rows, preflight_array_map_numeric_payload_charge
                  )
                  raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += charge_bytes
                  array_map_numeric_values[selected.name] = values
                end
              when "Map(String, Array(UInt64))"
                values = selected.reader.read_map_string_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if nested_elements > UInt64::MAX // 8_u64
                  raise CorruptPartError.new("selected Map nested Array byte count overflows")
                end
                value_bytes = nested_elements * 8_u64
                if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested Array bytes exceed materialization limit")
                end
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_array_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_array_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_uint64_values[selected.name] = values
              when "Map(String, Array(Nullable(UInt64)))"
                values = selected.reader.read_map_string_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if nested_elements > UInt64::MAX // 9_u64
                  raise CorruptPartError.new("selected Map nested nullable Array byte count overflows")
                end
                # Each nested Nullable(UInt64) element retains a null byte and
                # an eight-byte child slot, including hidden slots under NULL.
                value_bytes = nested_elements * 9_u64
                if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested nullable Array bytes exceed materialization limit")
                end
                if value_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + value_bytes
                expected_payload_bytes = preflight_map_string_array_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                # W68 has the same row/entry/Array-container accounting as
                # W63; its payload includes the nullable physical child bytes.
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_array_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_nullable_uint64_values[selected.name] = values
              when "Map(String, Array(Nullable(String)))"
                values = selected.reader.read_map_string_array_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                visible_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, array_values|
                    key_bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map visible String bytes exceed preflight") if key_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                    visible_bytes += key_bytes
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested String leaf count exceeds materialization limit")
                    end
                    leaves += array_values.size.to_u64
                    array_values.each do |value|
                      next unless value
                      value_bytes = value.not_nil!.bytesize.to_u64
                      raise CorruptPartError.new("selected Map visible String bytes exceed preflight") if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                      visible_bytes += value_bytes
                    end
                  end
                end
                expected_payload_bytes = preflight_map_string_array_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map visible String bytes exceed physical preflight") if visible_bytes > expected_payload_bytes
                charge_bytes = preflight_map_string_array_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map charge is smaller than its physical payload") if charge_bytes < expected_payload_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_nullable_string_values[selected.name] = values
              when "Map(UInt64, Array(Nullable(UInt64)))"
                values = selected.reader.read_map_uint64_array_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                nested_elements = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, array_values|
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - nested_elements
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    nested_elements += array_values.size.to_u64
                  end
                end
                if entries > UInt64::MAX // 8_u64 || nested_elements > UInt64::MAX // 9_u64
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                key_bytes = entries * 8_u64
                # Every Nullable(UInt64) slot includes one null-map byte and
                # the eight-byte child slot, even when the value is NULL.
                nested_bytes = nested_elements * 9_u64
                if nested_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
                  raise CorruptPartError.new("selected Map nested nullable Array bytes exceed materialization limit")
                end
                if nested_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + nested_bytes
                expected_payload_bytes = preflight_map_uint64_array_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_array_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_array_nullable_uint64_values[selected.name] = values
              when "Map(UInt64, Array(Nullable(String)))"
                values = selected.reader.read_map_uint64_array_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                visible_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, array_values|
                    if array_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested String leaf count exceeds materialization limit")
                    end
                    leaves += array_values.size.to_u64
                    array_values.each do |value|
                      next unless value
                      value_bytes = value.not_nil!.bytesize.to_u64
                      raise CorruptPartError.new("selected Map visible String bytes exceed materialization limit") if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - visible_bytes
                      visible_bytes += value_bytes
                    end
                  end
                end
                expected_payload_bytes = preflight_map_uint64_array_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                expected_charge_bytes = preflight_map_uint64_array_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                if entries > UInt64::MAX // 16_u64 || leaves > UInt64::MAX // 9_u64
                  raise CorruptPartError.new("selected Map physical payload accounting overflows")
                end
                entry_metadata_bytes = entries * 16_u64
                leaf_metadata_bytes = leaves * 9_u64
                if leaf_metadata_bytes > UInt64::MAX - entry_metadata_bytes
                  raise CorruptPartError.new("selected Map physical payload accounting overflows")
                end
                visible_floor = entry_metadata_bytes + leaf_metadata_bytes
                if visible_floor > expected_payload_bytes || visible_bytes > expected_payload_bytes - visible_floor
                  raise CorruptPartError.new("selected Map visible String bytes exceed physical preflight")
                end
                raise CorruptPartError.new("selected Map charge is smaller than its physical payload") if expected_charge_bytes < expected_payload_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if expected_charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += expected_charge_bytes
                map_uint64_array_nullable_string_values[selected.name] = values
              when "Map(String, String)"
                values = selected.reader.read_map_string_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                payload_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, value|
                    key_bytes = key.bytesize.to_u64
                    value_bytes = value.bytesize.to_u64
                    if key_bytes > UInt64::MAX - payload_bytes || value_bytes > UInt64::MAX - payload_bytes - key_bytes
                      raise CorruptPartError.new("selected Map key/value payload overflows")
                    end
                    payload_bytes += key_bytes + value_bytes
                  end
                end
                expected_payload_bytes = preflight_map_string_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                bytes = charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                map_string_string_values[selected.name] = values
              when "Map(String, Nullable(UInt64))"
                values = selected.reader.read_map_string_nullable_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, _value|
                    bytes = key.bytesize.to_u64
                    raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                    key_bytes += bytes
                  end
                end
                if entries > UInt64::MAX // 9_u64 || entries * 9_u64 > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = key_bytes + entries * 9_u64
                expected_payload_bytes = preflight_map_string_nullable_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/null/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_string_nullable_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_nullable_uint64_values[selected.name] = values
              when "Map(UInt64, Nullable(String))"
                values = selected.reader.read_map_uint64_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                visible_value_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, value|
                    next unless value
                    value_bytes = value.not_nil!.bytesize.to_u64
                    if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_value_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    visible_value_bytes += value_bytes
                  end
                end
                metadata_bytes = entries * 17_u64
                if metadata_bytes > UInt64::MAX - visible_value_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = metadata_bytes + visible_value_bytes
                expected_payload_bytes = preflight_map_uint64_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map decoded value payload exceeds preflight") if payload_bytes > expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, expected_payload_bytes)
                expected_charge_bytes = preflight_map_uint64_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_nullable_string_values[selected.name] = values
              when "Map(String, Nullable(String))"
                values = selected.reader.read_map_string_nullable_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                key_bytes = 0_u64
                visible_value_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, value|
                    bytes = key.bytesize.to_u64
                    if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - key_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    key_bytes += bytes
                    next unless value
                    value_bytes = value.not_nil!.bytesize.to_u64
                    if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_value_bytes
                      raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
                    end
                    visible_value_bytes += value_bytes
                  end
                end
                if entries > UInt64::MAX // 17_u64 || entries * 17_u64 > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                metadata_bytes = key_bytes + entries * 17_u64
                if visible_value_bytes > UInt64::MAX - metadata_bytes
                  raise CorruptPartError.new("selected Map key/null/value payload overflows")
                end
                payload_bytes = metadata_bytes + visible_value_bytes
                expected_payload_bytes = preflight_map_string_nullable_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map decoded value payload exceeds preflight") if payload_bytes > expected_payload_bytes
                charge_bytes = checked_map_tuple_materialization_charge(mark_rows, entries, expected_payload_bytes)
                expected_charge_bytes = preflight_map_string_nullable_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_nullable_string_values[selected.name] = values
              when "Map(UInt64, Array(UInt64))"
                values = selected.reader.read_map_uint64_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, nested_values|
                    if nested_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested Array element count exceeds materialization limit")
                    end
                    leaves += nested_values.size.to_u64
                  end
                end
                if entries > UInt64::MAX // 8_u64 || leaves > UInt64::MAX // 8_u64
                  raise CorruptPartError.new("selected Map physical payload accounting overflows")
                end
                key_bytes = entries * 8_u64
                leaf_bytes = leaves * 8_u64
                if leaf_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 || leaf_bytes > UInt64::MAX - key_bytes
                  raise CorruptPartError.new("selected Map physical payload accounting overflows")
                end
                payload_bytes = key_bytes + leaf_bytes
                expected_payload_bytes = preflight_map_uint64_array_uint64_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, entries, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_array_uint64_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_array_uint64_values[selected.name] = values
              when "Map(String, Array(String))"
                values = selected.reader.read_map_string_array_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                visible_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |key, nested_values|
                    key_bytes = key.bytesize.to_u64
                    if key_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                      raise CorruptPartError.new("selected Map visible String bytes exceed materialization limit")
                    end
                    visible_bytes += key_bytes
                    if nested_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested String leaf count exceeds materialization limit")
                    end
                    leaves += nested_values.size.to_u64
                    nested_values.each do |value|
                      value_bytes = value.bytesize.to_u64
                      if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                        raise CorruptPartError.new("selected Map visible String bytes exceed materialization limit")
                      end
                      visible_bytes += value_bytes
                    end
                  end
                end
                expected_payload_bytes = preflight_map_string_array_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                payload_bytes = checked_w73_string_array_payload_bytes(entries, leaves, visible_bytes)
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_string_materialization_charge(mark_rows, entries, leaves, payload_bytes)
                expected_charge_bytes = preflight_map_string_array_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_string_array_string_values[selected.name] = values
              when "Map(UInt64, Array(String))"
                values = selected.reader.read_map_uint64_array_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Map mark row count changed") unless values.size.to_u64 == mark_rows
                entries = 0_u64
                leaves = 0_u64
                visible_bytes = 0_u64
                values.each do |row|
                  if row.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
                    raise CorruptPartError.new("selected Map mark entry count exceeds materialization limit")
                  end
                  entries += row.size.to_u64
                  row.each do |_key, nested_values|
                    if nested_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
                      raise CorruptPartError.new("selected Map nested String leaf count exceeds materialization limit")
                    end
                    leaves += nested_values.size.to_u64
                    nested_values.each do |value|
                      value_bytes = value.bytesize.to_u64
                      if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_bytes
                        raise CorruptPartError.new("selected Map visible String bytes exceed materialization limit")
                      end
                      visible_bytes += value_bytes
                    end
                  end
                end
                expected_payload_bytes = preflight_map_uint64_array_string_payload_bytes[selected.name]? || raise(CorruptPartError.new("selected Map payload was not preflighted"))
                payload_bytes = checked_w73_string_array_payload_bytes(entries, leaves, visible_bytes)
                raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload_bytes
                charge_bytes = checked_map_string_array_string_materialization_charge(mark_rows, entries, leaves, payload_bytes)
                expected_charge_bytes = preflight_map_uint64_array_string_charge_bytes[selected.name]? || raise(CorruptPartError.new("selected Map charge was not preflighted"))
                raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge_bytes
                raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += charge_bytes
                map_uint64_array_string_values[selected.name] = values
              when .starts_with?("Map(UInt64, Array(Nullable("), .starts_with?("Map(String, Array(Nullable(")
                value_type = WidePart.map_uint64_array_nullable_numeric_value_type(selected.column_type) ||
                             WidePart.map_string_array_nullable_numeric_value_type(selected.column_type) ||
                             raise(UnsupportedFormatError.new("selected Map Array leaf is not an admitted nullable primitive numeric type"))
                values = read_numeric_map_array_rows(selected, mark_index, value_type, true)
                charge_bytes = verify_numeric_map_array_materialization(
                  selected, values, mark_rows, preflight_numeric_map_payload_charge
                )
                if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  raise CorruptPartError.new("selected Map Nullable Array mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += charge_bytes
                numeric_map_values[selected.name] = values
              when .starts_with?("Map(UInt64, Array("), .starts_with?("Map(String, Array(")
                value_type = WidePart.map_uint64_array_numeric_value_type(selected.column_type) ||
                             WidePart.map_string_array_numeric_value_type(selected.column_type) ||
                             raise(UnsupportedFormatError.new("selected Map Array leaf is not an admitted primitive numeric type"))
                values = read_numeric_map_array_rows(selected, mark_index, value_type)
                charge_bytes = verify_numeric_map_array_materialization(
                  selected, values, mark_rows, preflight_numeric_map_payload_charge
                )
                if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  raise CorruptPartError.new("selected Map Array mark exceeds aggregate materialization limit")
                end
                actual_string_bytes += charge_bytes
                numeric_map_values[selected.name] = values
              when .starts_with?("Nullable(")
                values = read_nullable_values(selected, mark_index)
                raise CorruptPartError.new("selected Nullable mark row count changed") unless nullable_array_size(values).to_u64 == mark_rows
                nullable_values[selected.name] = values
              else
                values = read_numeric_values(selected, mark_index)
                raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
                numeric_values[selected.name] = values
              end
            end
            part.object_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
              values, charge = ObjectColumnAdapter.materialize_mark(
                selected.reader,
                mark_index.to_i32,
                mark_rows,
                remaining_bytes
              )
              if charge > remaining_bytes
                raise CorruptPartError.new("selected Object mark exceeds aggregate materialization limit")
              end
              actual_string_bytes += charge
              object_documents[selected.name] = values
            end
            part.array_object_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
              values, charge = ArrayObjectColumnAdapter.materialize_mark(
                selected.reader,
                mark_index.to_i32,
                mark_rows,
                remaining_bytes
              )
              if charge > remaining_bytes
                raise CorruptPartError.new("selected Array(JSON) mark exceeds aggregate materialization limit")
              end
              actual_string_bytes += charge
              array_object_documents[selected.name] = values
            end
            recursive_values = Hash(String, Array(StorageColumnValue)).new
            part.recursive_readers.each do |selected|
              remaining_bytes = MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
              values, charge = RecursiveColumnAdapter.materialize_mark(
                selected.reader,
                selected.schema,
                mark_index.to_i32,
                mark_rows,
                remaining_bytes
              )
              if charge > remaining_bytes
                raise CorruptPartError.new("selected recursive Tuple mark exceeds aggregate materialization limit")
              end
              actual_string_bytes += charge
              recursive_values[selected.name] = values
            end

            mark_row_offset = selected_mark_row_start
            first_whole_mark_batch = whole_marks
            while mark_row_offset < selected_mark_row_end || first_whole_mark_batch
              first_whole_mark_batch = false
              remaining = selected_mark_row_end - mark_row_offset
              size = if whole_marks
                       remaining.to_i
                     else
                       remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
                     end
              aggregate_count_slices = Hash(String, Slice(BinaryValue)).new
              numeric_slices = Hash(String, WidePartNumericSlice).new
              string_slices = Hash(String, Slice(String)).new
              fixed_string_slices = Hash(String, Slice(String)).new
              nullable_slices = Hash(String, WidePartNullableSlice).new
              nullable_string_slices = Hash(String, WidePartNullableStringSlice).new
              nullable_fixed_string_slices = Hash(String, WidePartNullableStringSlice).new
              array_uint64_slices = Hash(String, Slice(Array(UInt64))).new
              array_nullable_uint64_slices = Hash(String, Slice(Array(UInt64?))).new
              array_string_slices = Hash(String, Slice(Array(String))).new
              array_array_uint64_slices = Hash(String, Slice(Array(Array(UInt64)))).new
              array_array_string_slices = Hash(String, Slice(Array(Array(String)))).new
              array_array_nullable_string_slices = Hash(String, WidePartArrayArrayNullableStringSlice).new
              array_array_nullable_uint64_slices = Hash(String, Slice(Array(Array(UInt64?)))).new
              array_array_numeric_slices = Hash(String, WidePartArrayArrayNumericSlice).new
              array_array_nullable_numeric_slices = Hash(String, WidePartArrayArrayNullableNumericSlice).new
              array_numeric_slices = Hash(String, WidePartArrayNumericSlice).new
              array_nullable_numeric_slices = Hash(String, WidePartArrayNullableNumericSlice).new
              array_bool_slices = Hash(String, WidePartArrayBoolSlice).new
              array_nullable_bool_slices = Hash(String, WidePartArrayNullableBoolSlice).new
              array_tuple_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
              array_tuple_nullable_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64?, String)))).new
              array_tuple_uint64_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
              variant_string_uint64_slices = Hash(String, Slice(VariantStringUInt64Value)).new
              variant_bool_string_uint64_slices = Hash(String, Slice(VariantBoolStringUInt64Value)).new
              array_nullable_string_slices = Hash(String, WidePartArrayNullableStringSlice).new
              tuple_string_slices = Hash(String, Slice(Tuple(UInt64, String))).new
              tuple_row_slices = Hash(String, Slice(WideTupleRow)).new
              generic_array_tuple_slices = Hash(String, Slice(WideArrayTupleRow)).new
              generic_map_tuple_slices = Hash(String, Slice(WideMapTupleRow)).new
              point_values_slices = Hash(String, Slice(WidePointValue)).new
              geo_array_slices = Hash(String, Slice(WideGeoArrayRow)).new
              geometry_slices = Hash(String, Slice(WideGeometryRow)).new
              map_uint64_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String)))).new
              map_uint64_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64)))).new
              map_string_uint64_slices = Hash(String, Slice(Array(Tuple(String, UInt64)))).new
              map_string_array_uint64_slices = Hash(String, Slice(Array(Tuple(String, Array(UInt64))))).new
              array_map_string_uint64_slices = Hash(String, Slice(Array(Array(Tuple(String, UInt64))))).new
              array_map_numeric_slices = Hash(String, WidePartArrayMapNumericSliceBase).new
              map_string_array_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(String, Array(UInt64?))))).new
              map_string_array_nullable_string_slices = Hash(String, Slice(Array(Tuple(String, Array(String?))))).new
              map_uint64_array_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64?))))).new
              map_uint64_array_nullable_string_slices = Hash(String, Slice(Array(Tuple(UInt64, Array(String?))))).new
              map_uint64_array_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, Array(UInt64))))).new
              map_string_array_string_slices = Hash(String, Slice(Array(Tuple(String, Array(String))))).new
              map_uint64_array_string_slices = Hash(String, Slice(Array(Tuple(UInt64, Array(String))))).new
              map_string_string_slices = Hash(String, Slice(Array(Tuple(String, String)))).new
              map_uint64_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(UInt64, UInt64?)))).new
              map_string_nullable_uint64_slices = Hash(String, Slice(Array(Tuple(String, UInt64?)))).new
              map_uint64_nullable_string_slices = Hash(String, Slice(Array(Tuple(UInt64, String?)))).new
              map_string_nullable_string_slices = Hash(String, Slice(Array(Tuple(String, String?)))).new
              numeric_map_uint64_slices = Hash(String, WidePartNumericMapSliceBase).new
              numeric_map_string_slices = Hash(String, WidePartNumericMapSliceBase).new
              part.readers.each do |selected|
                if values = aggregate_count_values[selected.name]?
                  aggregate_count_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = numeric_values[selected.name]?
                  numeric_slices[selected.name] = slice_numeric_values(values, mark_row_offset.to_i, size)
                elsif values = string_values[selected.name]?
                  string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = fixed_string_values[selected.name]?
                  fixed_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = nullable_values[selected.name]?
                  nullable_slices[selected.name] = slice_nullable_values(values, mark_row_offset.to_i, size)
                elsif values = nullable_string_values[selected.name]?
                  nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = nullable_fixed_string_values[selected.name]?
                  nullable_fixed_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_numeric_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_numeric_slices[selected.name] = selected_slice.as(WidePartArrayNumericSlice)
                  if selected.column_type == "Array(UInt64)"
                    array_uint64_slices[selected.name] = selected_slice.as(Slice(Array(UInt64)))
                  end
                elsif values = array_nullable_numeric_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_nullable_numeric_slices[selected.name] = selected_slice.as(WidePartArrayNullableNumericSlice)
                  if selected.column_type == "Array(Nullable(UInt64))"
                    array_nullable_uint64_slices[selected.name] = selected_slice.as(Slice(Array(UInt64?)))
                  end
                elsif values = array_bool_values[selected.name]?
                  array_bool_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_bool_values[selected.name]?
                  array_nullable_bool_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_uint64_values[selected.name]?
                  array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_uint64_values[selected.name]?
                  array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_uint64_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_array_uint64_slices[selected.name] = selected_slice
                  array_array_numeric_slices[selected.name] = selected_slice.as(WidePartArrayArrayNumericSlice)
                elsif values = array_array_string_values[selected.name]?
                  array_array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_nullable_string_values[selected.name]?
                  array_array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_array_nullable_uint64_values[selected.name]?
                  selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  array_array_nullable_uint64_slices[selected.name] = selected_slice
                  array_array_nullable_numeric_slices[selected.name] = selected_slice.as(WidePartArrayArrayNullableNumericSlice)
                elsif values = array_array_nullable_numeric_values[selected.name]?
                  array_array_nullable_numeric_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size].as(WidePartArrayArrayNullableNumericSlice)
                elsif values = array_array_numeric_values[selected.name]?
                  array_array_numeric_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size].as(WidePartArrayArrayNumericSlice)
                elsif values = array_string_values[selected.name]?
                  array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_nullable_string_values[selected.name]?
                  array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_uint64_string_values[selected.name]?
                  array_tuple_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_nullable_uint64_string_values[selected.name]?
                  array_tuple_nullable_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_tuple_uint64_uint64_values[selected.name]?
                  array_tuple_uint64_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = variant_string_uint64_values[selected.name]?
                  variant_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = variant_bool_string_uint64_values[selected.name]?
                  variant_bool_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = tuple_string_values[selected.name]?
                  tuple_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = tuple_row_values[selected.name]?
                  tuple_row_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = generic_array_tuple_rows[selected.name]?
                  generic_array_tuple_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = generic_map_tuple_rows[selected.name]?
                  generic_map_tuple_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_string_values[selected.name]?
                  map_uint64_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_uint64_values[selected.name]?
                  map_uint64_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_uint64_values[selected.name]?
                  map_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_uint64_values[selected.name]?
                  map_string_array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_map_string_uint64_values[selected.name]?
                  array_map_string_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_map_numeric_values[selected.name]?
                  array_map_numeric_slices[selected.name] = values.slice_rows(mark_row_offset.to_i, size)
                elsif values = map_string_array_nullable_uint64_values[selected.name]?
                  map_string_array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_nullable_string_values[selected.name]?
                  map_string_array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_array_nullable_uint64_values[selected.name]?
                  map_uint64_array_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_array_nullable_string_values[selected.name]?
                  map_uint64_array_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_array_uint64_values[selected.name]?
                  map_uint64_array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_array_string_values[selected.name]?
                  map_string_array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_array_string_values[selected.name]?
                  map_uint64_array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_string_values[selected.name]?
                  map_string_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_nullable_uint64_values[selected.name]?
                  map_uint64_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_nullable_uint64_values[selected.name]?
                  map_string_nullable_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_uint64_nullable_string_values[selected.name]?
                  map_uint64_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = map_string_nullable_string_values[selected.name]?
                  map_string_nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = numeric_map_values[selected.name]?
                  if WidePart.map_uint64_numeric_value_type(selected.column_type) ||
                     WidePart.map_uint64_nullable_numeric_value_type(selected.column_type) ||
                     WidePart.map_uint64_array_numeric_value_type(selected.column_type) ||
                     WidePart.map_uint64_array_nullable_numeric_value_type(selected.column_type)
                    numeric_map_uint64_slices[selected.name] = values.slice_rows(mark_row_offset.to_i, size)
                  else
                    numeric_map_string_slices[selected.name] = values.slice_rows(mark_row_offset.to_i, size)
                  end
                elsif values = geo_array_rows[selected.name]?
                  geo_array_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = geometry_rows[selected.name]?
                  geometry_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = point_values[selected.name]?
                  point_values_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif qbit_values.has_key?(selected.name) || nullable_qbit_values.has_key?(selected.name)
                  # QBit slices are installed on the constructed batch below.
                else
                  raise CorruptPartError.new("selected typed column was not materialized")
                end
              end
              batch = WidePartTableBatch.new(
                part_index.to_i32,
                part.name,
                part.path,
                mark_index.to_i32,
                mark_row_offset,
                mark_start_part_row_offset &+ mark_row_offset,
                source_row_offset &+ mark_start_part_row_offset &+ mark_row_offset,
                @columns,
                part.column_types,
                numeric_slices,
                string_slices,
                nullable_slices,
                nullable_string_slices,
                fixed_string_slices,
                nullable_fixed_string_slices,
                array_uint64_slices,
                array_string_slices,
                tuple_string_slices,
                map_uint64_string_slices,
                map_uint64_uint64_slices,
                array_nullable_uint64_slices,
                array_array_uint64_slices,
                array_array_nullable_uint64_slices,
                array_array_numeric_slices,
                array_array_nullable_numeric_slices,
                array_numeric_slices,
                array_nullable_numeric_slices,
                array_nullable_string_slices,
                array_bool_slices,
                array_nullable_bool_slices,
                array_tuple_uint64_string_slices,
                array_tuple_nullable_uint64_string_slices,
                map_string_uint64_slices,
                map_string_string_slices,
                map_uint64_nullable_uint64_slices,
                map_string_nullable_uint64_slices,
                map_uint64_nullable_string_slices,
                map_string_nullable_string_slices,
                array_tuple_uint64_uint64_slices,
                variant_string_uint64_slices,
                variant_bool_string_uint64_slices,
                array_array_string_slices,
                array_array_nullable_string_slices,
                map_string_array_uint64_slices,
                map_string_array_nullable_uint64_slices,
                map_uint64_array_nullable_uint64_slices,
                map_string_array_nullable_string_values: map_string_array_nullable_string_slices,
                map_uint64_array_nullable_string_values: map_uint64_array_nullable_string_slices,
                map_uint64_array_uint64_values: map_uint64_array_uint64_slices,
                map_string_array_string_values: map_string_array_string_slices,
                map_uint64_array_string_values: map_uint64_array_string_slices,
                map_uint64_numeric_values: numeric_map_uint64_slices,
                map_string_numeric_values: numeric_map_string_slices,
                array_map_string_uint64_values: array_map_string_uint64_slices,
                array_map_numeric_values: array_map_numeric_slices,
                tuple_row_values: tuple_row_slices
              )
              part.readers.each do |selected|
                if values = aggregate_count_slices[selected.name]?
                  batch.install_aggregate_count_states(selected.name, values, size)
                elsif values = generic_array_tuple_slices[selected.name]?
                  if WideNestedTypePlan.for_type(selected.column_type)
                    batch.install_nested_rows(selected.name, values, size)
                  else
                    batch.install_array_tuple_rows(selected.name, values, size)
                  end
                elsif values = generic_map_tuple_slices[selected.name]?
                  batch.install_map_tuple_rows(selected.name, values, size)
                elsif values = geo_array_slices[selected.name]?
                  batch.install_geo_array_rows(selected.name, values, size)
                elsif values = geometry_slices[selected.name]?
                  batch.install_geometry_rows(selected.name, values, size)
                elsif values = point_values_slices[selected.name]?
                  batch.install_point_values(selected.name, values, size)
                elsif values = qbit_values[selected.name]?
                  selected_values = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  batch.install_qbit_values(selected.name, selected_values, size)
                elsif values = nullable_qbit_values[selected.name]?
                  selected_values = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                  batch.install_nullable_qbit_values(selected.name, selected_values, size)
                end
              end
              part.object_readers.each do |selected|
                values = object_documents[selected.name]? ||
                         raise(CorruptPartError.new("selected Object column was not materialized"))
                selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                batch.install_object_documents(selected.name, selected_slice, size)
              end
              part.array_object_readers.each do |selected|
                values = array_object_documents[selected.name]? ||
                         raise(CorruptPartError.new("selected Array(JSON) column was not materialized"))
                selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                batch.install_array_object_documents(selected.name, selected_slice, size)
              end
              part.recursive_readers.each do |selected|
                values = recursive_values[selected.name]? ||
                         raise(CorruptPartError.new("selected recursive Tuple column was not materialized"))
                selected_slice = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                batch.install_recursive_values(selected.name, selected_slice, size)
              end
              yield batch
              mark_row_offset &+= size.to_u64
              break if whole_marks
            end
          end

          raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
          source_row_offset &+= part.row_count
        ensure
          part.readers.each do |selected|
            selected.reader.release_low_cardinality_string_scan_cache if selected.column_type == "LowCardinality(String)"
          end
        end
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def validate_complete_array_object_schedules : Nil
      @entries.each do |part|
        part.array_object_readers.each do |selected|
          reader = selected.reader
          unless reader.row_count == part.row_count.to_u64 &&
                 reader.mark_count == part.mark_row_counts.size &&
                 reader.mark_row_counts == part.mark_row_counts
            raise CorruptPartError.new("selected Array(JSON) outer grid differs from its part")
          end
          ArrayObjectColumnAdapter.validate_complete_schedule(reader)
        end
      end
      nil
    end

    private def validate_complete_recursive_schedules : Nil
      @entries.each do |part|
        part.recursive_readers.each do |selected|
          reader = selected.reader
          unless reader.row_count == part.row_count.to_u64 &&
                 reader.mark_count == part.mark_row_counts.size &&
                 reader.mark_row_counts == part.mark_row_counts
            raise CorruptPartError.new("selected recursive Tuple grid differs from its part")
          end
          RecursiveColumnAdapter.validate_complete_schedule(reader)
        end
      end
      nil
    end

    private def preflight_coordinate_selected_marks(
      candidate_marks : Array(Array(Int32))?,
      window_rows : {UInt64, UInt64}?,
    ) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        selected_marks = candidate_marks ? candidate_marks[part_index] : nil
        selected_index = 0
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          mark_start_part_row_offset = part_row_offset
          part_row_offset &+= mark_rows

          selected_mark = true
          if part_marks = selected_marks
            selected_mark = selected_index < part_marks.size && part_marks[selected_index] == mark_index
            selected_index += 1 if selected_mark
          end
          next unless selected_mark

          if window = window_rows
            mark_source_start = source_row_offset &+ mark_start_part_row_offset
            mark_source_end = mark_source_start &+ mark_rows
            window_start, window_end = window
            next if mark_rows == 0_u64 || window_start >= mark_source_end || window_end <= mark_source_start
          end

          part.readers.each do |selected|
            if GeometryColumnAdapter.type?(selected.column_type)
              selected.reader.validate_geometry_mark_range_structure(selected.name, mark_index, 1)
            elsif PointColumnAdapter.type?(selected.column_type)
              selected.reader.validate_point_mark_range_structure(selected.name, mark_index, 1)
            elsif GeoArrayColumnAdapter.type?(selected.column_type)
              selected.reader.validate_geo_array_mark_range_structure(selected.name, mark_index, 1)
            end
          end
        end
        source_row_offset &+= part.row_count
      end
      nil
    end

    private def preflight_array_map_leaf_selected_marks(
      candidate_marks : Array(Array(Int32))?,
      window_rows : {UInt64, UInt64}?,
    ) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        selected_marks = candidate_marks ? candidate_marks[part_index] : nil
        selected_index = 0
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          mark_start = part_row_offset
          part_row_offset &+= mark_rows
          selected = true
          if marks = selected_marks
            selected = selected_index < marks.size && marks[selected_index] == mark_index
            selected_index += 1 if selected
          end
          next unless selected

          if window = window_rows
            start_row, end_row = window
            source_mark_start = source_row_offset &+ mark_start
            source_mark_end = source_mark_start &+ mark_rows
            next if mark_rows == 0_u64 || start_row >= source_mark_end || end_row <= source_mark_start
          end

          aggregate_array_map_leaf_charge = 0_u64
          aggregate_includes_w83 = false
          aggregate_includes_w84 = false
          part.readers.each do |selected_reader|
            charge = if WidePart.supports_array_map_string_leaf_type?(selected_reader.column_type)
                       selected_reader.reader.array_map_string_leaf_mark_range_materialization_preflight(
                         selected_reader.name, mark_index, 1
                       )[:charge_bytes]
                     elsif WidePart.supports_array_map_bool_leaf_type?(selected_reader.column_type)
                       aggregate_includes_w83 = true
                       selected_reader.reader.array_map_bool_leaf_mark_range_materialization_preflight(
                         selected_reader.name, mark_index, 1
                       )[:charge_bytes]
                     elsif WidePart.supports_array_map_array_leaf_type?(selected_reader.column_type)
                       aggregate_includes_w84 = true
                       selected_reader.reader.array_map_array_leaf_mark_range_materialization_preflight(
                         selected_reader.name, mark_index, 1
                       )[:charge_bytes]
                     else
                       next
                     end
            if charge > MAX_MARK_MATERIALIZED_BYTES.to_u64 - aggregate_array_map_leaf_charge
              message = if aggregate_includes_w84
                          "selected W82/W83/W84 Array(Map) leaf columns exceed aggregate materialization limit"
                        elsif aggregate_includes_w83
                          "selected W82/W83 Array(Map) leaf columns exceed aggregate materialization limit"
                        else
                          "selected W82 Array(Map) columns exceed aggregate materialization limit"
                        end
              raise CorruptPartError.new(message)
            end
            aggregate_array_map_leaf_charge += charge
          end
        end
        raise CorruptPartError.new("part row count changed during W82/W83/W84 preflight") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end
      raise CorruptPartError.new("source row count mismatch during W82/W83/W84 preflight") unless source_row_offset == @total_row_count
      nil
    end

    private def scan_rows(batch_rows : Int, & : WidePartTableBatch -> Nil) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          column_values = Array(WidePartNumericArray).new(@columns.size)
          part.readers.each do |selected|
            values = read_numeric_values(selected, mark_index)
            raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
            column_values << values
          end

          mark_row_offset = 0_u64
          while mark_row_offset < mark_rows
            remaining = mark_rows - mark_row_offset
            size = remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
            slices = Array(WidePartNumericSlice).new(column_values.size)
            column_values.each do |values|
              slices << slice_numeric_values(values, mark_row_offset.to_i, size)
            end
            batch = WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              mark_row_offset,
              # Preflight bounds each part and the concatenated source before
              # these additions; WidePart also proves marks sum to row_count.
              part_row_offset &+ mark_row_offset,
              source_row_offset &+ part_row_offset &+ mark_row_offset,
              @columns,
              part.column_types,
              slices
            )
            yield batch
            mark_row_offset &+= size.to_u64
          end

          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def read_numeric_values(selected : ColumnReader, mark_index : Int) : WidePartNumericArray
      reader = selected.reader
      type = selected.column_type
      if WidePart.supports_uuid_type?(type)
        return reader.read_uuids_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_ipv4_type?(type)
        return reader.read_ipv4s_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_ipv6_type?(type)
        return reader.read_ipv6s_mark_range(selected.name, mark_index, 1)
      elsif type == "Bool"
        return reader.read_bool_mark_range(selected.name, mark_index, 1)
      elsif type == "BFloat16"
        return reader.read_bfloat16_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif type == "Int128"
        return reader.read_int128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "UInt128"
        return reader.read_uint128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Int256"
        return reader.read_int256_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "UInt256"
        return reader.read_uint256_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal32_scale(type).nil?
        return reader.read_decimal32_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal64_scale(type).nil?
        return reader.read_decimal64_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal128_scale(type).nil?
        return reader.read_decimal128_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal256_scale(type).nil?
        return reader.read_decimal256_raw_mark_range(selected.name, mark_index, 1)
      end

      if datetime_type = DateTimeColumnType.parse_leaf(type)
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          return reader.read_datetime_seconds_mark_range(selected.name, mark_index, 1)
        when DateTimeColumnType::Family::DateTime64
          return reader.read_datetime64_ticks_mark_range(selected.name, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported exact DateTime type")
        end
      end

      if interval_type = IntervalColumnType.parse(type)
        if interval_type.shape == IntervalColumnType::Shape::Scalar
          return reader.read_interval_counts_mark_range(selected.name, mark_index, 1)
        end
      end

      if aggregate_type = SimpleAggregateColumnType.parse(type)
        if aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar
          if temporal_type = aggregate_type.temporal_storage_type
            function = aggregate_type.function
            storage_type_name = temporal_type.type_name
            return case temporal_type.family
            when TemporalStorageType::Family::Date
              reader.read_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, UInt16)
            when TemporalStorageType::Family::Date32, TemporalStorageType::Family::Time
              reader.read_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, Int32)
            when TemporalStorageType::Family::DateTime
              reader.read_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, UInt32)
            when TemporalStorageType::Family::DateTime64, TemporalStorageType::Family::Time64
              reader.read_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, Int64)
            else
              raise UnsupportedFormatError.new("unsupported temporal SimpleAggregateFunction family")
            end
          end
          if decimal_type = aggregate_type.decimal_type
            function = aggregate_type.function
            return case decimal_type.storage_width
            when  4 then reader.read_simple_aggregate_decimal32_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when  8 then reader.read_simple_aggregate_decimal64_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when 16 then reader.read_simple_aggregate_decimal128_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when 32 then reader.read_simple_aggregate_decimal256_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            else         raise UnsupportedFormatError.new("unsupported Decimal SimpleAggregateFunction width")
            end
          end
          return case aggregate_type.storage_type_name
          when "UInt8"    then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt8)
          when "UInt16"   then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt16)
          when "UInt32"   then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt32)
          when "UInt64"   then reader.read_simple_aggregate_uint64_mark_range(selected.name, mark_index, 1)
          when "Int8"     then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int8)
          when "Int16"    then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int16)
          when "Int32"    then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int32)
          when "Int64"    then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int64)
          when "Float32"  then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Float32)
          when "Float64"  then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Float64)
          when "Int128"   then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int128)
          when "UInt128"  then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt128)
          when "Int256"   then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int256Value)
          when "UInt256"  then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt256Value)
          when "BFloat16" then reader.read_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, BFloat16Value)
          else                 raise UnsupportedFormatError.new("unsupported SimpleAggregateFunction carrier")
          end
        end
      end

      case selected.column_type
      when "Date"
        reader.read_date_codes_mark_range(selected.name, mark_index, 1)
      when "Date32"
        reader.read_date32_codes_mark_range(selected.name, mark_index, 1)
      when "DateTime"
        reader.read_datetime_seconds_mark_range(selected.name, mark_index, 1)
      when "Time"
        reader.read_time_seconds_mark_range(selected.name, mark_index, 1)
      when .starts_with?("DateTime64(")
        unless WidePart.datetime64_scale(selected.column_type)
          raise UnsupportedFormatError.new("unsupported exact DateTime64 type")
        end
        reader.read_datetime64_ticks_mark_range(selected.name, mark_index, 1)
      when .starts_with?("Time64(")
        unless WidePart.time64_scale(selected.column_type)
          raise UnsupportedFormatError.new("unsupported exact Time64 type")
        end
        reader.read_time64_ticks_mark_range(selected.name, mark_index, 1)
      when "UInt8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Int8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Int16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Int32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Int64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Float32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Float64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def read_array_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNumericArray
      case element_type
      when "UInt8"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int64)
      when "Int128"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "Float32"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_numeric_mark_range(column, mark_index, 1, Float64)
      when "BFloat16"
        reader.read_array_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array numeric leaf type")
      end
    end

    private def read_array_array_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "UInt8"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int64)
      when "Float32"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Float64)
      when "Int128"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "BFloat16"
        reader.read_array_array_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(T)) numeric leaf type")
      end
    end

    private def read_array_array_nullable_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "UInt8"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int64)
      when "Float32"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Float64)
      when "Int128"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "BFloat16"
        reader.read_array_array_nullable_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric leaf type")
      end
    end

    private def read_array_array_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "Date"
        reader.read_array_array_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_array_date32_codes_mark_range(column, mark_index, 1)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          reader.read_array_array_datetime_seconds_mark_range(column, mark_index, 1)
        when DateTimeColumnType::Family::DateTime64
          reader.read_array_array_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested temporal Array leaf type")
        end
      end
    end

    private def read_array_array_nullable_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "Date"
        reader.read_array_array_nullable_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_array_nullable_date32_codes_mark_range(column, mark_index, 1)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          reader.read_array_array_nullable_datetime_seconds_mark_range(column, mark_index, 1)
        when DateTimeColumnType::Family::DateTime64
          reader.read_array_array_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type")
        end
      end
    end

    private def read_array_array_time_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNumericArray
      case element_type
      when "Time"
        reader.read_array_array_time_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.time64_scale(element_type)
          reader.read_array_array_time64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested Time Array leaf type")
        end
      end
    end

    private def read_array_array_nullable_time_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayArrayNullableNumericArray
      case element_type
      when "Time"
        reader.read_array_array_nullable_time_seconds_mark_range(column, mark_index, 1)
      else
        if WidePart.time64_scale(element_type)
          reader.read_array_array_nullable_time64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nested nullable Time Array leaf type")
        end
      end
    end

    private def read_array_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNumericArray
      case element_type
      when "Date"
        reader.read_array_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_date32_codes_mark_range(column, mark_index, 1)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          reader.read_array_datetime_seconds_mark_range(column, mark_index, 1)
        when DateTimeColumnType::Family::DateTime64
          reader.read_array_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported temporal Array leaf type")
        end
      end
    end

    private def read_array_nullable_temporal_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNullableNumericArray
      case element_type
      when "Date"
        reader.read_array_nullable_date_codes_mark_range(column, mark_index, 1)
      when "Date32"
        reader.read_array_nullable_date32_codes_mark_range(column, mark_index, 1)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nullable temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          reader.read_array_nullable_datetime_seconds_mark_range(column, mark_index, 1)
        when DateTimeColumnType::Family::DateTime64
          reader.read_array_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("unsupported nullable temporal Array leaf type")
        end
      end
    end

    private def read_array_nullable_numeric_values(
      reader : WidePart,
      column : String,
      mark_index : Int,
      element_type : String,
    ) : WidePartArrayNullableNumericArray
      case element_type
      when "UInt8"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
      when "Int8"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int8)
      when "Int16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int16)
      when "Int32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int32)
      when "Int64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int64)
      when "Int128"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int128)
      when "UInt128"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt128)
      when "Int256"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Int256Value)
      when "UInt256"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, UInt256Value)
      when "Float32"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Float32)
      when "Float64"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, Float64)
      when "BFloat16"
        reader.read_array_nullable_numeric_mark_range(column, mark_index, 1, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported Array nullable numeric leaf type")
      end
    end

    private def array_nullable_numeric_materialized_bytes(
      values : WidePartArrayNullableNumericArray,
      element_type : String,
    ) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Nullable(T)) mark element count exceeds materialization limit")
        end
        elements += row_elements
      end

      bytes_per_element = (1 + WidePart.array_numeric_payload_width(element_type)).to_u64
      if elements > UInt64::MAX // bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(T)) byte count overflows")
      end
      elements * bytes_per_element
    end

    private def array_nullable_string_materialized_bytes(
      values : WidePartArrayNullableStringArray,
    ) : {UInt64, UInt64}
      elements = 0_u64
      visible_bytes = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Nullable(String)) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |value|
          next if value.nil?

          string_bytes = value.bytesize.to_u64
          if string_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - visible_bytes
            raise CorruptPartError.new("selected Array(Nullable(String)) visible byte count exceeds materialization limit")
          end
          visible_bytes += string_bytes
        end
      end

      slot_bytes_per_element = WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if elements > UInt64::MAX // slot_bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(String)) slot byte count overflows")
      end
      slot_bytes = elements * slot_bytes_per_element
      row_bytes_per_element = WidePart::ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
      if values.size.to_u64 > UInt64::MAX // row_bytes_per_element
        raise CorruptPartError.new("selected Array(Nullable(String)) row byte count overflows")
      end
      row_bytes = values.size.to_u64 * row_bytes_per_element
      if slot_bytes > UInt64::MAX - row_bytes || visible_bytes > UInt64::MAX - slot_bytes - row_bytes
        raise CorruptPartError.new("selected Array(Nullable(String)) materialized byte count overflows")
      end
      {visible_bytes, visible_bytes + slot_bytes + row_bytes}
    end

    private def array_tuple_materialized_bytes(
      values : Array(Array(Tuple(T, String))),
      slot_bytes_per_element : UInt64,
    ) : UInt64 forall T
      elements = 0_u64
      string_bytes = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Tuple) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |_number, value|
          value_bytes = value.bytesize.to_u64
          if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - string_bytes
            raise CorruptPartError.new("selected Array(Tuple) String bytes exceed materialization limit")
          end
          string_bytes += value_bytes
        end
      end

      outer_rows = values.size.to_u64
      if outer_rows > UInt64::MAX // 8_u64 || elements > UInt64::MAX // slot_bytes_per_element
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      outer_bytes = outer_rows * WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      slot_bytes = elements * slot_bytes_per_element
      if slot_bytes > UInt64::MAX - outer_bytes || string_bytes > UInt64::MAX - outer_bytes - slot_bytes
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      total_bytes = outer_bytes + slot_bytes + string_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_tuple_uint64_uint64_materialized_bytes(
      values : Array(Array(Tuple(UInt64, UInt64))),
    ) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(Tuple) mark element count exceeds materialization limit")
        end
        elements += row_elements
      end

      outer_rows = values.size.to_u64
      if outer_rows > UInt64::MAX // WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES ||
         elements > UInt64::MAX // 16_u64
        raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows")
      end
      outer_bytes = outer_rows * WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      leaf_bytes = elements * 16_u64
      raise CorruptPartError.new("selected Array(Tuple) materialization charge overflows") if leaf_bytes > UInt64::MAX - outer_bytes
      total_bytes = outer_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def numeric_map_preflight(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      string_keys : Bool,
      nullable : Bool = false,
    ) : {UInt64, UInt64}
      case value_type
      when "UInt8"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, UInt8, nullable)
      when "UInt16"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, UInt16, nullable)
      when "UInt32"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, UInt32, nullable)
      when "Int8"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Int8, nullable)
      when "Int16"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Int16, nullable)
      when "Int32"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Int32, nullable)
      when "Int64"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Int64, nullable)
      when "Float32"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Float32, nullable)
      when "Float64"
        numeric_map_preflight_for_type(selected, mark_index, string_keys, Float64, nullable)
      else
        raise UnsupportedFormatError.new("unsupported exact Map numeric value type")
      end
    end

    private def nullable_numeric_map_preflight(selected : ColumnReader, mark_index : Int32, value_type : String, string_keys : Bool) : {UInt64, UInt64}
      numeric_map_preflight(selected, mark_index, value_type, string_keys, true)
    end

    private def numeric_map_preflight_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable : Bool,
    ) : {UInt64, UInt64} forall T
      if nullable && string_keys
        selected.reader.map_string_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif nullable
        selected.reader.map_uint64_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif string_keys
        selected.reader.map_string_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      else
        selected.reader.map_uint64_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      end
    end

    private def numeric_map_array_preflight(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      string_keys : Bool,
      nullable_values : Bool = false,
    ) : {UInt64, UInt64}
      case value_type
      when "UInt8"   then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, UInt8, nullable_values)
      when "UInt16"  then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, UInt16, nullable_values)
      when "UInt32"  then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, UInt32, nullable_values)
      when "UInt64"  then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, UInt64, nullable_values)
      when "Int8"    then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Int8, nullable_values)
      when "Int16"   then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Int16, nullable_values)
      when "Int32"   then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Int32, nullable_values)
      when "Int64"   then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Int64, nullable_values)
      when "Float32" then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Float32, nullable_values)
      when "Float64" then numeric_map_array_preflight_for_type(selected, mark_index, string_keys, Float64, nullable_values)
      else
        raise UnsupportedFormatError.new("unsupported exact Map Array numeric leaf type")
      end
    end

    private def numeric_map_array_preflight_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable_values : Bool,
    ) : {UInt64, UInt64} forall T
      if nullable_values && string_keys
        selected.reader.map_string_array_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif nullable_values
        selected.reader.map_uint64_array_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif string_keys
        selected.reader.map_string_array_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      else
        selected.reader.map_uint64_array_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      end
    end

    private def read_numeric_map_array_rows(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      nullable_values : Bool = false,
    ) : WidePartNumericMapRowsBase
      string_keys = !WidePart.map_string_array_numeric_value_type(selected.column_type).nil? ||
                    !WidePart.map_string_array_nullable_numeric_value_type(selected.column_type).nil?
      case value_type
      when "UInt8"   then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, UInt8, nullable_values)
      when "UInt16"  then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, UInt16, nullable_values)
      when "UInt32"  then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, UInt32, nullable_values)
      when "UInt64"  then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, UInt64, nullable_values)
      when "Int8"    then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Int8, nullable_values)
      when "Int16"   then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Int16, nullable_values)
      when "Int32"   then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Int32, nullable_values)
      when "Int64"   then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Int64, nullable_values)
      when "Float32" then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Float32, nullable_values)
      when "Float64" then read_numeric_map_array_rows_for_type(selected, mark_index, string_keys, Float64, nullable_values)
      else
        raise UnsupportedFormatError.new("unsupported exact Map Array numeric leaf type")
      end
    end

    private def read_numeric_map_array_rows_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable_values : Bool,
    ) : WidePartNumericMapRowsBase forall T
      if nullable_values && string_keys
        values = selected.reader.read_map_string_array_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNullableNumericMapArrayRows(String, T).new(values)
      elsif nullable_values
        values = selected.reader.read_map_uint64_array_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNullableNumericMapArrayRows(UInt64, T).new(values)
      elsif string_keys
        values = selected.reader.read_map_string_array_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNumericMapArrayRows(String, T).new(values)
      else
        values = selected.reader.read_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNumericMapArrayRows(UInt64, T).new(values)
      end
    end

    private def verify_numeric_map_array_materialization(
      selected : ColumnReader,
      values : WidePartNumericMapRowsBase,
      mark_rows : UInt64,
      preflight : Hash(String, {UInt64, UInt64}),
    ) : UInt64
      raise CorruptPartError.new("selected Map Array mark row count changed") unless values.row_count == mark_rows
      expected_payload, expected_charge = preflight[selected.name]? || raise(CorruptPartError.new("selected Map Array was not preflighted"))
      payload_bytes = values.payload_bytes
      raise CorruptPartError.new("selected Map Array key/value payload differs from preflight") unless payload_bytes == expected_payload
      charge_bytes = checked_map_string_array_uint64_materialization_charge(mark_rows, values.entry_count, payload_bytes)
      raise CorruptPartError.new("selected Map Array materialization charge differs from preflight") unless charge_bytes == expected_charge
      charge_bytes
    end

    private def array_map_string_leaf_preflight(
      selected : ColumnReader,
      mark_index : Int32,
    ) : {UInt64, UInt64}
      preflight = selected.reader.array_map_string_leaf_mark_range_materialization_preflight(selected.name, mark_index, 1)
      {preflight[:payload_bytes], preflight[:charge_bytes]}
    end

    private def array_map_bool_leaf_preflight(
      selected : ColumnReader,
      mark_index : Int32,
    ) : {UInt64, UInt64}
      preflight = selected.reader.array_map_bool_leaf_mark_range_materialization_preflight(selected.name, mark_index, 1)
      {preflight[:payload_bytes], preflight[:charge_bytes]}
    end

    private def read_array_map_string_leaf_rows(
      selected : ColumnReader,
      mark_index : Int32,
    ) : WidePartArrayMapNumericRowsBase
      case selected.column_type
      when "Array(Map(UInt64, String))"
        rows = selected.reader.read_array_map_uint64_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapStringLeafRows(UInt64, String).new(rows)
      when "Array(Map(String, String))"
        rows = selected.reader.read_array_map_string_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapStringLeafRows(String, String).new(rows)
      when "Array(Map(UInt64, Nullable(String)))"
        rows = selected.reader.read_array_map_uint64_nullable_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapStringLeafRows(UInt64, String?).new(rows)
      when "Array(Map(String, Nullable(String)))"
        rows = selected.reader.read_array_map_string_nullable_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapStringLeafRows(String, String?).new(rows)
      else
        raise UnsupportedFormatError.new("selected column is not an exact W82 Array(Map) String leaf")
      end
    end

    private def read_array_map_bool_leaf_rows(
      selected : ColumnReader,
      mark_index : Int32,
    ) : WidePartArrayMapNumericRowsBase
      case selected.column_type
      when "Array(Map(UInt64, Bool))"
        rows = selected.reader.read_array_map_uint64_bool_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapBoolLeafRows(UInt64, Bool).new(rows)
      when "Array(Map(String, Bool))"
        rows = selected.reader.read_array_map_string_bool_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapBoolLeafRows(String, Bool).new(rows)
      when "Array(Map(UInt64, Nullable(Bool)))"
        rows = selected.reader.read_array_map_uint64_nullable_bool_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapBoolLeafRows(UInt64, Bool?).new(rows)
      when "Array(Map(String, Nullable(Bool)))"
        rows = selected.reader.read_array_map_string_nullable_bool_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapBoolLeafRows(String, Bool?).new(rows)
      else
        raise UnsupportedFormatError.new("selected column is not an exact W83 Array(Map) Bool leaf")
      end
    end

    private def array_map_numeric_preflight(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      string_keys : Bool,
      nullable : Bool,
    ) : {UInt64, UInt64}
      case value_type
      when "UInt8"   then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, UInt8, nullable)
      when "UInt16"  then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, UInt16, nullable)
      when "UInt32"  then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, UInt32, nullable)
      when "UInt64"  then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, UInt64, nullable)
      when "Int8"    then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Int8, nullable)
      when "Int16"   then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Int16, nullable)
      when "Int32"   then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Int32, nullable)
      when "Int64"   then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Int64, nullable)
      when "Float32" then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Float32, nullable)
      when "Float64" then array_map_numeric_preflight_for_type(selected, mark_index, string_keys, Float64, nullable)
      else
        raise UnsupportedFormatError.new("unsupported exact Array(Map) numeric value type")
      end
    end

    private def array_map_numeric_preflight_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable : Bool,
    ) : {UInt64, UInt64} forall T
      if nullable && string_keys
        selected.reader.array_map_string_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif nullable
        selected.reader.array_map_uint64_nullable_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      elsif string_keys
        selected.reader.array_map_string_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      else
        selected.reader.array_map_uint64_numeric_mark_range_materialization_preflight(selected.name, mark_index, 1, type)
      end
    end

    private def read_array_map_array_leaf_rows(
      selected : ColumnReader,
      mark_index : Int32,
    ) : WidePartArrayMapArrayLeafRowsBase
      shape = WidePart.array_map_array_leaf_shape(selected.column_type) ||
              raise(UnsupportedFormatError.new("selected column is not an exact W84/W85 Array(Map) Array leaf"))
      case shape
      when {"UInt64", "UInt8"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, UInt8)
        WidePartArrayMapArrayLeafRows(UInt64, UInt8).new(rows)
      when {"UInt64", "UInt16"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, UInt16)
        WidePartArrayMapArrayLeafRows(UInt64, UInt16).new(rows)
      when {"UInt64", "UInt32"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, UInt32)
        WidePartArrayMapArrayLeafRows(UInt64, UInt32).new(rows)
      when {"UInt64", "UInt64"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, UInt64)
        WidePartArrayMapArrayLeafRows(UInt64, UInt64).new(rows)
      when {"UInt64", "Int8"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Int8)
        WidePartArrayMapArrayLeafRows(UInt64, Int8).new(rows)
      when {"UInt64", "Int16"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Int16)
        WidePartArrayMapArrayLeafRows(UInt64, Int16).new(rows)
      when {"UInt64", "Int32"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Int32)
        WidePartArrayMapArrayLeafRows(UInt64, Int32).new(rows)
      when {"UInt64", "Int64"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Int64)
        WidePartArrayMapArrayLeafRows(UInt64, Int64).new(rows)
      when {"UInt64", "Float32"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Float32)
        WidePartArrayMapArrayLeafRows(UInt64, Float32).new(rows)
      when {"UInt64", "Float64"}
        rows = selected.reader.read_array_map_uint64_array_numeric_mark_range(selected.name, mark_index, 1, Float64)
        WidePartArrayMapArrayLeafRows(UInt64, Float64).new(rows)
      when {"String", "UInt8"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, UInt8)
        WidePartArrayMapArrayLeafRows(String, UInt8).new(rows)
      when {"String", "UInt16"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, UInt16)
        WidePartArrayMapArrayLeafRows(String, UInt16).new(rows)
      when {"String", "UInt32"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, UInt32)
        WidePartArrayMapArrayLeafRows(String, UInt32).new(rows)
      when {"String", "UInt64"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, UInt64)
        WidePartArrayMapArrayLeafRows(String, UInt64).new(rows)
      when {"String", "Int8"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Int8)
        WidePartArrayMapArrayLeafRows(String, Int8).new(rows)
      when {"String", "Int16"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Int16)
        WidePartArrayMapArrayLeafRows(String, Int16).new(rows)
      when {"String", "Int32"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Int32)
        WidePartArrayMapArrayLeafRows(String, Int32).new(rows)
      when {"String", "Int64"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Int64)
        WidePartArrayMapArrayLeafRows(String, Int64).new(rows)
      when {"String", "Float32"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Float32)
        WidePartArrayMapArrayLeafRows(String, Float32).new(rows)
      when {"String", "Float64"}
        rows = selected.reader.read_array_map_string_array_numeric_mark_range(selected.name, mark_index, 1, Float64)
        WidePartArrayMapArrayLeafRows(String, Float64).new(rows)
      when {"UInt64", "String"}
        rows = selected.reader.read_array_map_uint64_array_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapArrayLeafRows(UInt64, String).new(rows)
      when {"String", "String"}
        rows = selected.reader.read_array_map_string_array_string_mark_range(selected.name, mark_index, 1)
        WidePartArrayMapArrayLeafRows(String, String).new(rows)
      else
        raise UnsupportedFormatError.new("selected column is not an exact W84/W85 Array(Map) Array leaf")
      end
    end

    private def verify_array_map_array_leaf_materialization(
      selected : ColumnReader,
      values : WidePartArrayMapArrayLeafRowsBase,
      mark_rows : UInt64,
      preflight : Hash(String, {UInt64, UInt64}),
    ) : UInt64
      raise CorruptPartError.new("selected W84 mark row count changed") unless values.row_count == mark_rows
      expected_payload, expected_charge = preflight[selected.name]? || raise(CorruptPartError.new("selected W84 mark was not preflighted"))
      payload_bytes = values.payload_bytes
      raise CorruptPartError.new("selected W84 key/value payload differs from preflight") unless payload_bytes == expected_payload

      shape = WidePart.array_map_array_leaf_shape(selected.column_type) || raise(CorruptPartError.new("selected W84 type changed after preflight"))
      charge_bytes = checked_array_map_array_leaf_materialization_charge(
        mark_rows,
        values.map_count,
        values.entry_count,
        values.value_count,
        payload_bytes,
        shape[0] == "String",
        shape[1] == "String"
      )
      raise CorruptPartError.new("selected W84 materialization charge differs from preflight") unless charge_bytes == expected_charge
      charge_bytes
    end

    private def checked_array_map_array_leaf_materialization_charge(
      rows : UInt64,
      maps : UInt64,
      entries : UInt64,
      values : UInt64,
      payload_bytes : UInt64,
      string_keys : Bool,
      string_values : Bool,
    ) : UInt64
      row_width = WidePart::ARRAY_MAP_ROW_ACCOUNTING_BYTES + 8_u64
      map_width = WidePart::ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES + 8_u64
      entry_width = WidePart::ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES + WidePart::MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES + 8_u64
      value_width = string_values ? WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES + 8_u64 : 0_u64
      entry_width += WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES + 8_u64 if string_keys
      if rows > WidePart::MAX_ARRAY_MARK_ROWS || maps > WidePart::MAX_ARRAY_MARK_ELEMENTS ||
         entries > WidePart::MAX_ARRAY_MARK_ELEMENTS || values > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("selected W84 container count exceeds materialization limit")
      end
      if rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width ||
         entries > UInt64::MAX // entry_width || (value_width > 0 && values > UInt64::MAX // value_width)
        raise CorruptPartError.new("selected W84 materialization charge overflows")
      end
      row_bytes = rows * row_width
      map_bytes = maps * map_width
      entry_bytes = entries * entry_width
      value_slot_bytes = values * value_width
      if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
         value_slot_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes - value_slot_bytes
        raise CorruptPartError.new("selected W84 materialization charge overflows")
      end
      charge_bytes = row_bytes + map_bytes + entry_bytes + value_slot_bytes + payload_bytes
      raise CorruptPartError.new("selected W84 materialization charge exceeds per-mark limit") if charge_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
      charge_bytes
    end

    private def read_array_map_numeric_rows(selected : ColumnReader, mark_index : Int32) : WidePartArrayMapNumericRowsBase
      if value_type = WidePart.array_map_uint64_numeric_value_type(selected.column_type)
        read_array_map_numeric_rows_for_type(selected, mark_index, value_type, false, false)
      elsif value_type = WidePart.array_map_string_numeric_value_type(selected.column_type)
        read_array_map_numeric_rows_for_type(selected, mark_index, value_type, true, false)
      elsif value_type = WidePart.array_map_uint64_nullable_numeric_value_type(selected.column_type)
        read_array_map_numeric_rows_for_type(selected, mark_index, value_type, false, true)
      elsif value_type = WidePart.array_map_string_nullable_numeric_value_type(selected.column_type)
        read_array_map_numeric_rows_for_type(selected, mark_index, value_type, true, true)
      else
        raise UnsupportedFormatError.new("selected column is not an exact numeric Array(Map)")
      end
    end

    private def read_array_map_numeric_rows_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      string_keys : Bool,
      nullable : Bool,
    ) : WidePartArrayMapNumericRowsBase
      case value_type
      when "UInt8"   then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, UInt8, nullable)
      when "UInt16"  then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, UInt16, nullable)
      when "UInt32"  then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, UInt32, nullable)
      when "UInt64"  then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, UInt64, nullable)
      when "Int8"    then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Int8, nullable)
      when "Int16"   then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Int16, nullable)
      when "Int32"   then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Int32, nullable)
      when "Int64"   then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Int64, nullable)
      when "Float32" then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Float32, nullable)
      when "Float64" then read_array_map_numeric_rows_for_primitive(selected, mark_index, string_keys, Float64, nullable)
      else
        raise UnsupportedFormatError.new("unsupported exact Array(Map) numeric value type")
      end
    end

    private def read_array_map_numeric_rows_for_primitive(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable : Bool,
    ) : WidePartArrayMapNumericRowsBase forall T
      if nullable && string_keys
        rows = selected.reader.read_array_map_string_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartArrayMapNullableNumericRows(String, T).new(rows)
      elsif nullable
        rows = selected.reader.read_array_map_uint64_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartArrayMapNullableNumericRows(UInt64, T).new(rows)
      elsif string_keys
        rows = selected.reader.read_array_map_string_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartArrayMapNumericRows(String, T).new(rows)
      else
        rows = selected.reader.read_array_map_uint64_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartArrayMapNumericRows(UInt64, T).new(rows)
      end
    end

    private def verify_array_map_numeric_materialization(
      selected : ColumnReader,
      values : WidePartArrayMapNumericRowsBase,
      mark_rows : UInt64,
      preflight : Hash(String, {UInt64, UInt64}),
    ) : UInt64
      raise CorruptPartError.new("selected Array(Map) mark row count changed") unless values.row_count == mark_rows
      expected_payload, expected_charge = preflight[selected.name]? || raise(CorruptPartError.new("selected Array(Map) numeric mark was not preflighted"))
      payload_bytes = values.payload_bytes
      raise CorruptPartError.new("selected Array(Map) key/value payload differs from preflight") unless payload_bytes == expected_payload
      charge_bytes = checked_array_map_numeric_materialization_charge(mark_rows, values.map_count, values.entry_count, payload_bytes)
      raise CorruptPartError.new("selected Array(Map) materialization charge differs from preflight") unless charge_bytes == expected_charge
      charge_bytes
    end

    private def checked_array_map_numeric_materialization_charge(
      rows : UInt64,
      maps : UInt64,
      entries : UInt64,
      payload_bytes : UInt64,
    ) : UInt64
      row_width = WidePart::ARRAY_MAP_ROW_ACCOUNTING_BYTES
      map_width = WidePart::ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES
      entry_width = WidePart::ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > WidePart::MAX_ARRAY_MARK_ROWS || maps > WidePart::MAX_ARRAY_MARK_ELEMENTS || entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("selected Array(Map) container count exceeds materialization limit")
      end
      if rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width || entries > UInt64::MAX // entry_width
        raise CorruptPartError.new("selected Array(Map) materialization charge overflows")
      end
      row_bytes = rows * row_width
      map_bytes = maps * map_width
      entry_bytes = entries * entry_width
      if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes
        raise CorruptPartError.new("selected Array(Map) materialization charge overflows")
      end
      charge_bytes = row_bytes + map_bytes + entry_bytes + payload_bytes
      raise CorruptPartError.new("selected Array(Map) mark exceeds aggregate materialization limit") if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
      charge_bytes
    end

    private def read_numeric_map_rows(selected : ColumnReader, mark_index : Int32) : WidePartNumericMapRowsBase
      if value_type = WidePart.map_uint64_numeric_value_type(selected.column_type)
        read_numeric_map_rows_for_type(selected, mark_index, value_type, false, false)
      elsif value_type = WidePart.map_string_numeric_value_type(selected.column_type)
        read_numeric_map_rows_for_type(selected, mark_index, value_type, true, false)
      elsif value_type = WidePart.map_uint64_nullable_numeric_value_type(selected.column_type)
        read_numeric_map_rows_for_type(selected, mark_index, value_type, false, true)
      elsif value_type = WidePart.map_string_nullable_numeric_value_type(selected.column_type)
        read_numeric_map_rows_for_type(selected, mark_index, value_type, true, true)
      else
        raise UnsupportedFormatError.new("selected column is not an exact numeric Map")
      end
    end

    private def read_numeric_map_rows_for_type(
      selected : ColumnReader,
      mark_index : Int32,
      value_type : String,
      string_keys : Bool,
      nullable : Bool,
    ) : WidePartNumericMapRowsBase
      case value_type
      when "UInt8"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, UInt8, nullable)
      when "UInt16"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, UInt16, nullable)
      when "UInt32"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, UInt32, nullable)
      when "Int8"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Int8, nullable)
      when "Int16"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Int16, nullable)
      when "Int32"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Int32, nullable)
      when "Int64"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Int64, nullable)
      when "Float32"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Float32, nullable)
      when "Float64"
        read_numeric_map_rows_for_primitive(selected, mark_index, string_keys, Float64, nullable)
      else
        raise UnsupportedFormatError.new("unsupported exact Map numeric value type")
      end
    end

    private def read_numeric_map_rows_for_primitive(
      selected : ColumnReader,
      mark_index : Int32,
      string_keys : Bool,
      type : T.class,
      nullable : Bool,
    ) : WidePartNumericMapRowsBase forall T
      if nullable && string_keys
        rows = selected.reader.read_map_string_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNullableNumericMapRows(String, T).new(rows)
      elsif nullable
        rows = selected.reader.read_map_uint64_nullable_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNullableNumericMapRows(UInt64, T).new(rows)
      elsif string_keys
        rows = selected.reader.read_map_string_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNumericMapRows(String, T).new(rows)
      else
        rows = selected.reader.read_map_uint64_numeric_mark_range(selected.name, mark_index, 1, type)
        WidePartNumericMapRows(UInt64, T).new(rows)
      end
    end

    private def verify_numeric_map_materialization(
      selected : ColumnReader,
      values : WidePartNumericMapRowsBase,
      mark_rows : UInt64,
      preflight : Hash(String, {UInt64, UInt64}),
    ) : UInt64
      raise CorruptPartError.new("selected Map mark row count changed") unless values.row_count == mark_rows
      expected_payload, expected_charge = preflight[selected.name]? || raise(CorruptPartError.new("selected Map was not preflighted"))
      payload_bytes = values.payload_bytes
      raise CorruptPartError.new("selected Map key/value payload differs from preflight") unless payload_bytes == expected_payload
      charge_bytes = checked_map_tuple_materialization_charge(
        mark_rows, values.entry_count, payload_bytes, WidePart::NUMERIC_MAP_ROW_ACCOUNTING_BYTES
      )
      raise CorruptPartError.new("selected Map materialization charge differs from preflight") unless charge_bytes == expected_charge
      charge_bytes
    end

    private def checked_map_tuple_materialization_charge(
      rows : UInt64,
      entries : UInt64,
      payload_bytes : UInt64,
      row_width : UInt64 = WidePart::ARRAY_TUPLE_ROW_ACCOUNTING_BYTES,
    ) : UInt64
      entry_width = WidePart::ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > WidePart::MAX_ARRAY_MARK_ROWS || entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("selected Map mark container count exceeds materialization limit")
      end
      if rows > UInt64::MAX // row_width || entries > UInt64::MAX // entry_width
        raise CorruptPartError.new("selected Map materialization charge overflows")
      end
      row_bytes = rows * row_width
      entry_bytes = entries * entry_width
      if entry_bytes > UInt64::MAX - row_bytes || payload_bytes > UInt64::MAX - row_bytes - entry_bytes
        raise CorruptPartError.new("selected Map materialization charge overflows")
      end
      charge_bytes = row_bytes + entry_bytes + payload_bytes
      if charge_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
      end
      charge_bytes
    end

    private def checked_map_string_array_uint64_materialization_charge(rows : UInt64, entries : UInt64, payload_bytes : UInt64) : UInt64
      charge_bytes = checked_map_tuple_materialization_charge(rows, entries, payload_bytes)
      array_width = WidePart::MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES
      if entries > UInt64::MAX // array_width
        raise CorruptPartError.new("selected Map nested Array materialization charge overflows")
      end
      array_bytes = entries * array_width
      if array_bytes > UInt64::MAX - charge_bytes
        raise CorruptPartError.new("selected Map nested Array materialization charge overflows")
      end
      total_bytes = charge_bytes + array_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Map mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def checked_w73_string_array_payload_bytes(entries : UInt64, leaves : UInt64, visible_bytes : UInt64) : UInt64
      if entries > WidePart::MAX_ARRAY_MARK_ELEMENTS || leaves > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("selected Map entry or leaf count exceeds materialization limit")
      end
      if entries > UInt64::MAX // 16_u64 || leaves > UInt64::MAX // 8_u64
        raise CorruptPartError.new("selected Map physical payload accounting overflows")
      end
      entry_metadata_bytes = entries * 16_u64
      leaf_metadata_bytes = leaves * 8_u64
      if leaf_metadata_bytes > UInt64::MAX - entry_metadata_bytes ||
         visible_bytes > UInt64::MAX - entry_metadata_bytes - leaf_metadata_bytes
        raise CorruptPartError.new("selected Map physical payload accounting overflows")
      end
      payload_bytes = entry_metadata_bytes + leaf_metadata_bytes + visible_bytes
      if payload_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64
        raise CorruptPartError.new("selected Map physical payload exceeds materialization limit")
      end
      payload_bytes
    end

    private def checked_map_string_array_string_materialization_charge(rows : UInt64, entries : UInt64, leaves : UInt64, payload_bytes : UInt64) : UInt64
      charge_bytes = checked_map_string_array_uint64_materialization_charge(rows, entries, payload_bytes)
      # Preserve the nested String object/header slot for every leaf, even for
      # empty strings; the physical payload alone does not charge that storage.
      leaf_slot_width = WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if leaves > UInt64::MAX // leaf_slot_width
        raise CorruptPartError.new("selected Map nested String materialization charge overflows")
      end
      leaf_bytes = leaves * leaf_slot_width
      if leaf_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 || charge_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - leaf_bytes
        raise CorruptPartError.new("selected Map nested String materialization charge exceeds limit")
      end
      charge_bytes + leaf_bytes
    end

    # Charge both the physical child bytes (including hidden NULL slots) and
    # bounded per-element/row bookkeeping before materializing a selected mark.
    private def array_fixed_string_charge_bytes(raw_bytes : UInt64, width : Int32, mark_rows : UInt64, nullable : Bool) : UInt64
      slot_bytes = width.to_u64 + (nullable ? 1_u64 : 0_u64)
      raise CorruptPartError.new("selected Array(FixedString(N)) child bytes are misaligned") unless raw_bytes % slot_bytes == 0_u64
      elements = raw_bytes // slot_bytes
      raise CorruptPartError.new("selected Array(FixedString(N)) mark element count exceeds materialization limit") if elements > WidePart::MAX_ARRAY_MARK_ELEMENTS

      element_accounting = elements * WidePart::ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      row_accounting = mark_rows * WidePart::ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
      raise CorruptPartError.new("selected Array(FixedString(N)) accounting overflows") if raw_bytes > UInt64::MAX - element_accounting - row_accounting
      raw_bytes + element_accounting + row_accounting
    end

    private def checked_array_fixed_string_elements(values, width : Int32) : UInt64
      elements = 0_u64
      values.each do |row|
        row_elements = row.size.to_u64
        if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - elements
          raise CorruptPartError.new("selected Array(FixedString(N)) mark element count exceeds materialization limit")
        end
        elements += row_elements
        row.each do |value|
          next if value.nil?
          raise CorruptPartError.new("selected Array(FixedString(N)) element width changed") unless value.bytesize == width
        end
      end
      elements
    end

    private def slice_numeric_values(values : WidePartNumericArray, offset : Int, size : Int) : WidePartNumericSlice
      case values
      when Array(UInt8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int128)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt128)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(BFloat16Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Bool)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UUIDValue)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv4Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv6Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def read_nullable_values(selected : ColumnReader, mark_index : Int) : WidePartNullableArray
      reader = selected.reader
      type = selected.column_type
      if WidePart.supports_nullable_uuid_type?(type)
        return reader.read_nullable_uuids_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_nullable_ipv4_type?(type)
        return reader.read_nullable_ipv4s_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_nullable_ipv6_type?(type)
        return reader.read_nullable_ipv6s_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Bool)"
        return reader.read_nullable_bool_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(BFloat16)"
        return reader.read_nullable_bfloat16_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal32_scale(type).nil?
        return reader.read_nullable_decimal32_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal64_scale(type).nil?
        return reader.read_nullable_decimal64_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Int128)"
        return reader.read_nullable_int128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(UInt128)"
        return reader.read_nullable_uint128_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Int256)"
        return reader.read_nullable_int256_raw_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(UInt256)"
        return reader.read_nullable_uint256_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal128_scale(type).nil?
        return reader.read_nullable_decimal128_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal256_scale(type).nil?
        return reader.read_nullable_decimal256_raw_mark_range(selected.name, mark_index, 1)
      end

      if datetime_type = DateTimeColumnType.parse(type)
        if datetime_type.shape == DateTimeColumnType::Shape::Nullable &&
           datetime_type.family == DateTimeColumnType::Family::DateTime
          return reader.read_nullable_datetime_seconds_mark_range(selected.name, mark_index, 1)
        end
      end

      if interval_type = IntervalColumnType.parse(type)
        if interval_type.shape == IntervalColumnType::Shape::Nullable
          return reader.read_nullable_interval_counts_mark_range(selected.name, mark_index, 1)
        end
      end

      if aggregate_type = SimpleAggregateColumnType.parse(type)
        if aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable
          if temporal_type = aggregate_type.temporal_storage_type
            function = aggregate_type.function
            storage_type_name = temporal_type.type_name
            return case temporal_type.family
            when TemporalStorageType::Family::Date
              reader.read_nullable_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, UInt16)
            when TemporalStorageType::Family::Date32, TemporalStorageType::Family::Time
              reader.read_nullable_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, Int32)
            when TemporalStorageType::Family::DateTime
              reader.read_nullable_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, UInt32)
            when TemporalStorageType::Family::DateTime64, TemporalStorageType::Family::Time64
              reader.read_nullable_simple_aggregate_temporal_raw_mark_range(selected.name, mark_index, 1, function, storage_type_name, Int64)
            else
              raise UnsupportedFormatError.new("unsupported Nullable temporal SimpleAggregateFunction family")
            end
          end
          if decimal_type = aggregate_type.decimal_type
            function = aggregate_type.function
            return case decimal_type.storage_width
            when  4 then reader.read_nullable_simple_aggregate_decimal32_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when  8 then reader.read_nullable_simple_aggregate_decimal64_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when 16 then reader.read_nullable_simple_aggregate_decimal128_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            when 32 then reader.read_nullable_simple_aggregate_decimal256_raw_mark_range(selected.name, mark_index, 1, function, decimal_type.precision, decimal_type.scale)
            else         raise UnsupportedFormatError.new("unsupported Nullable Decimal SimpleAggregateFunction width")
            end
          end
          return case aggregate_type.storage_type_name
          when "UInt8"    then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt8)
          when "UInt16"   then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt16)
          when "UInt32"   then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt32)
          when "UInt64"   then reader.read_nullable_simple_aggregate_uint64_mark_range(selected.name, mark_index, 1)
          when "Int8"     then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int8)
          when "Int16"    then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int16)
          when "Int32"    then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int32)
          when "Int64"    then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int64)
          when "Float32"  then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Float32)
          when "Float64"  then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Float64)
          when "Int128"   then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int128)
          when "UInt128"  then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt128)
          when "Int256"   then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, Int256Value)
          when "UInt256"  then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, UInt256Value)
          when "BFloat16" then reader.read_nullable_simple_aggregate_numeric_mark_range(selected.name, mark_index, 1, BFloat16Value)
          else                 raise UnsupportedFormatError.new("unsupported Nullable SimpleAggregateFunction carrier")
          end
        end
      end

      case selected.column_type
      when "Nullable(Date)"     then reader.read_nullable_date_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(Date32)"   then reader.read_nullable_date32_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(DateTime)" then reader.read_nullable_datetime_seconds_mark_range(selected.name, mark_index, 1)
      when "Nullable(Time)"     then reader.read_nullable_time_seconds_mark_range(selected.name, mark_index, 1)
      when "Nullable(UInt8)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "Nullable(UInt16)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "Nullable(UInt32)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "Nullable(UInt64)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Nullable(Int8)"     then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Nullable(Int16)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Nullable(Int32)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Nullable(Int64)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Nullable(Float32)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Nullable(Float64)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        if WidePart.nullable_datetime64_scale(selected.column_type)
          return reader.read_nullable_datetime64_ticks_mark_range(selected.name, mark_index, 1)
        elsif WidePart.nullable_time64_scale(selected.column_type)
          return reader.read_nullable_time64_ticks_mark_range(selected.name, mark_index, 1)
        end
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def nullable_array_size(values : WidePartNullableArray) : Int
      case values
      when Array(UInt8?)           then values.size
      when Array(UInt16?)          then values.size
      when Array(UInt32?)          then values.size
      when Array(UInt64?)          then values.size
      when Array(Int8?)            then values.size
      when Array(Int16?)           then values.size
      when Array(Int32?)           then values.size
      when Array(Int64?)           then values.size
      when Array(Int128?)          then values.size
      when Array(UInt128?)         then values.size
      when Array(Int256Value?)     then values.size
      when Array(UInt256Value?)    then values.size
      when Array(Decimal256Value?) then values.size
      when Array(BFloat16Value?)   then values.size
      when Array(Bool?)            then values.size
      when Array(Float32?)         then values.size
      when Array(Float64?)         then values.size
      when Array(UUIDValue?)       then values.size
      when Array(IPv4Value?)       then values.size
      when Array(IPv6Value?)       then values.size
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def slice_nullable_values(values : WidePartNullableArray, offset : Int, size : Int) : WidePartNullableSlice
      case values
      when Array(UInt8?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8?)            then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int128?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt128?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int256Value?)     then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt256Value?)    then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value?) then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(BFloat16Value?)   then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Bool?)            then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UUIDValue?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv4Value?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv6Value?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def initialize(
      parts : Array(String),
      columns : Array(String),
      @numeric_mode : Bool,
      @typed_mode : Bool,
      projection_name : String? = nil,
      flattened_context : FlattenedNestedTableContext? = nil,
    )
      @flattened_context = flattened_context
      if flattened_context && (!@typed_mode || @numeric_mode || projection_name)
        raise UnsupportedFormatError.new("flattened Nested table context requires a direct typed reader")
      end
      raise BoundsError.new("no parts selected") if parts.empty?
      raise BoundsError.new("part count exceeds limit") if parts.size > MAX_PARTS
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > MAX_COLUMNS
      validate_projection_name(projection_name) if projection_name

      @columns = Array(String).new(columns.size)
      seen_columns = Set(String).new
      columns.each do |column|
        raise BoundsError.new("column name is empty or exceeds limit") if column.empty? || column.bytesize > MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if seen_columns.includes?(column)
        seen_columns << column
        stored_column = if flattened_context
                          String.new(column.to_slice)
                        else
                          column.dup
                        end
        @columns << stored_column
      end

      @entries = Array(PartEntry).new(parts.size)
      seen_paths = Set(String).new
      selected_parts = Array({String, String, MergeTreePartInfo}).new(parts.size)
      parts.each do |requested_path|
        path, name, info = validate_selected_part(requested_path)
        raise BoundsError.new("duplicate selected part path") if seen_paths.includes?(path)
        seen_paths << path
        selected_parts << {path, name, info}
      end
      reject_overlapping_parts(selected_parts)

      # Validate the complete physical child set before opening any child
      # checksums or readers. A projection may be materialized in only some
      # parent parts, so absence is a hard error rather than an empty segment.
      selected_read_paths = Array(String).new(parts.size)
      if projection_name
        selected_parts.each do |selected_part|
          selected_read_paths << validate_selected_projection_child(selected_part[0], projection_name)
        end
      else
        selected_parts.each do |selected_part|
          selected_read_paths << selected_part[0]
        end
      end

      total_rows = 0_u64
      total_marks = 0_u64
      expected_column_types = nil.as(Array(String)?)
      expected_column_sources = nil.as(Array({String, String, String})?)
      expected_aggregate_count_key_name = nil.as(String?)

      # selected_parts remains in caller order. The parsed identities above
      # are used only for the overlap guard; they do not imply Active status.
      selected_parts.each_with_index do |selected_part, part_index|
        parent_path = selected_part[0]
        name = selected_part[1]
        path = selected_read_paths[part_index]
        readers = Array(ColumnReader).new(@columns.size)
        aggregate_count_key_reader = nil.as(ColumnReader?)
        aggregate_count_key_name = nil.as(String?)
        object_readers = Array(ObjectColumnReaderEntry).new
        array_object_readers = Array(ArrayObjectColumnReaderEntry).new
        recursive_readers = Array(RecursiveColumnReaderEntry).new
        expected_mark_rows = nil.as(Array(UInt64)?)
        expected_row_count = nil.as(UInt64?)
        current_column_types = Array(String).new(@columns.size)
        current_column_sources = Array({String, String, String}).new(@columns.size)
        checksums = PartChecksums.open(path)

        @columns.each do |column|
          object_declaration = nil.as(String?)
          array_object_declaration = nil.as(String?)
          recursive_declaration = nil.as(String?)
          if @typed_mode && !@numeric_mode && flattened_context.nil?
            object_declaration = WidePart.selected_json_declaration(path, column)
            array_object_declaration = WidePart.selected_array_json_declaration(path, column)
            recursive_declaration = WidePart.selected_recursive_json_declaration(path, column)
            if projection_name && object_declaration
              raise UnsupportedFormatError.new("Object columns are unsupported in typed projections")
            end
            if projection_name && array_object_declaration
              raise UnsupportedFormatError.new("Array(JSON) columns are unsupported in typed projections")
            end
            if projection_name && recursive_declaration
              raise UnsupportedFormatError.new("recursive Tuple JSON columns are unsupported in typed projections")
            end
          end

          mark_rows = [] of UInt64
          column_type = ""
          column_source = {"", "", ""}
          column_row_count = 0_u64
          selected_checksum_names = [] of String
          if source_declaration = object_declaration
            object_reader = ObjectColumnAdapter.open(path, column, source_declaration)
            mark_rows = object_reader.mark_row_counts
            raise BoundsError.new("mark count exceeds per-reader limit") if mark_rows.size > MAX_MARKS_PER_READER
            column_row_count = object_reader.row_count
            column_type = object_reader.schema_declaration
            column_source = {column, column, object_reader.schema_declaration}
            selected_checksum_names = object_reader.selected_checksum_names
            object_readers << ObjectColumnReaderEntry.new(column, object_reader, column_type)
          elsif source_declaration = array_object_declaration
            array_object_reader = ArrayObjectColumnAdapter.open(path, column, source_declaration)
            ArrayObjectColumnAdapter.validate_complete_schedule(array_object_reader)
            mark_rows = array_object_reader.mark_row_counts
            raise BoundsError.new("mark count exceeds per-reader limit") if mark_rows.size > MAX_MARKS_PER_READER
            column_row_count = array_object_reader.row_count
            column_type = array_object_reader.schema_declaration
            column_source = {column, column, array_object_reader.source_declaration}
            selected_checksum_names = array_object_reader.selected_checksum_names
            array_object_readers << ArrayObjectColumnReaderEntry.new(column, array_object_reader, column_type)
          elsif source_declaration = recursive_declaration
            recursive_schema = RecursiveColumnAdapter.schema_for_source_declaration(source_declaration)
            recursive_reader = RecursiveColumnAdapter.open(path, column, recursive_schema, source_declaration)
            RecursiveColumnAdapter.validate_complete_schedule(recursive_reader)
            mark_rows = recursive_reader.mark_row_counts
            raise BoundsError.new("mark count exceeds per-reader limit") if mark_rows.size > MAX_MARKS_PER_READER
            column_row_count = recursive_reader.row_count
            column_type = recursive_reader.schema_declaration
            column_source = {column, column, recursive_reader.source_declaration}
            selected_checksum_names = recursive_reader.selected_checksum_names
            recursive_readers << RecursiveColumnReaderEntry.new(column, recursive_reader, recursive_schema, column_type)
          else
            reader = if context = flattened_context
                       context.open_reader(path, column)
                     elsif @numeric_mode
                       WidePart.open_numeric(path, column)
                     elsif @typed_mode
                       WidePart.open_typed(path, column)
                     else
                       WidePart.open(path, column)
                     end
            raise BoundsError.new("mark count exceeds per-reader limit") if reader.mark_count > MAX_MARKS_PER_READER
            mark_rows = reader.mark_row_counts
            column_row_count = reader.row_count
            column_type = reader.column_type
            if flattened_context
              column_source = {
                String.new(column.to_slice),
                String.new(reader.source_column_name.to_slice),
                String.new(reader.source_column_type.to_slice),
              }
            else
              column_source = {column, reader.source_column_name, reader.source_column_type}
            end
            selected_checksum_names = reader.selected_checksum_names
            if WideAggregateCountStoragePlan.for_type_name(column_type)
              if projection_name
                raise UnsupportedFormatError.new("AggregateFunction(count) is unsupported in typed projections")
              end
              count_pair = WideAggregateCountPairAdmission.open(
                path,
                reader,
                checksums,
                MAX_MARKS_PER_READER,
                MAX_MARK_ROWS
              )
              count_key_name = count_pair.key_name
              if prior_key_name = aggregate_count_key_name
                raise CorruptPartError.new("selected AggregateFunction(count) columns disagree on their UInt64 sibling") unless prior_key_name == count_key_name
              end
              aggregate_count_key_name = count_key_name
              aggregate_count_key_reader = ColumnReader.new(count_key_name, count_pair.key_reader)
            end
            readers << ColumnReader.new(column, reader)
          end

          mark_rows.each do |rows|
            raise BoundsError.new("mark row count exceeds limit") if rows > MAX_MARK_ROWS
          end

          if current_rows = expected_row_count
            raise CorruptPartError.new("selected columns have different row counts") unless column_row_count == current_rows
          else
            expected_row_count = column_row_count
          end

          if current_marks = expected_mark_rows
            raise CorruptPartError.new("selected columns have different mark row counts") unless mark_rows == current_marks
          else
            expected_mark_rows = mark_rows
          end

          selected_checksum_names.each do |checksum_name|
            checksums.validate_selected_entries(path, checksum_name)
          end
          current_column_types << column_type
          current_column_sources << column_source
          total_marks = checked_total_marks(total_marks, mark_rows.size.to_u64)
        end

        if current_types = expected_column_types
          raise CorruptPartError.new("selected columns have different types across parts") unless current_column_types == current_types
        else
          expected_column_types = current_column_types
        end
        if current_sources = expected_column_sources
          raise CorruptPartError.new("selected columns have different source schemas across parts") unless current_column_sources == current_sources
        else
          expected_column_sources = current_column_sources
        end
        if count_key_name = aggregate_count_key_name
          if expected_key_name = expected_aggregate_count_key_name
            raise CorruptPartError.new("AggregateFunction(count) UInt64 sibling name differs across parts") unless count_key_name == expected_key_name
          else
            expected_aggregate_count_key_name = count_key_name
          end
        end

        row_count = expected_row_count || raise(CorruptPartError.new("selected part has no readers"))
        mark_row_counts = expected_mark_rows || raise(CorruptPartError.new("selected part has no mark rows"))
        total_rows = checked_total_rows(total_rows, row_count)
        @entries << PartEntry.new(name, parent_path, row_count, mark_row_counts, readers, aggregate_count_key_reader, object_readers, array_object_readers, recursive_readers, current_column_types, current_column_sources)
      end

      @part_count = @entries.size.to_i32
      @total_row_count = total_rows
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    private def array_array_uint64_materialized_bytes(values : Array(Array(Array(UInt64)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(UInt64)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(UInt64)) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_elements > max_count
        raise CorruptPartError.new("selected Array(Array(UInt64)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * 8_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(UInt64)) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(UInt64)) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_string_materialized_bytes(values : Array(Array(Array(String)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_strings = 0_u64
      payload_bytes = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(String)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_strings = inner.size.to_u64
          if row_leaf_strings > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_strings
            raise CorruptPartError.new("selected Array(Array(String)) leaf string count exceeds materialization limit")
          end
          leaf_strings += row_leaf_strings
          inner.each do |value|
            value_bytes = value.bytesize.to_u64
            if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - payload_bytes
              raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit")
            end
            payload_bytes += value_bytes
          end
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_strings > max_count
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      string_size_bytes = leaf_strings * 8_u64
      if inner_bytes > UInt64::MAX - outer_bytes || string_size_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      metadata_bytes = outer_bytes + inner_bytes + string_size_bytes
      if payload_bytes > UInt64::MAX - metadata_bytes
        raise CorruptPartError.new("selected Array(Array(String)) byte count overflows")
      end
      total_bytes = metadata_bytes + payload_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(String)) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_string_materialized_bytes(values : WidePartArrayArrayNullableStringArray) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_strings = 0_u64
      visible_payload_bytes = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(String))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_strings = inner.size.to_u64
          if row_leaf_strings > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_strings
            raise CorruptPartError.new("selected Array(Array(Nullable(String))) leaf string count exceeds materialization limit")
          end
          leaf_strings += row_leaf_strings
          inner.each do |value|
            next unless string_value = value
            value_bytes = string_value.bytesize.to_u64
            if value_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - visible_payload_bytes
              raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit")
            end
            visible_payload_bytes += value_bytes
          end
        end
      end

      max_offset_count = UInt64::MAX // 8_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_strings > UInt64::MAX // 9_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_strings * 9_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      metadata_bytes = outer_bytes + inner_bytes + leaf_bytes
      if visible_payload_bytes > UInt64::MAX - metadata_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) byte count overflows")
      end
      total_bytes = metadata_bytes + visible_payload_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(String))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_uint64_materialized_bytes(values : Array(Array(Array(UInt64?)))) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_count = UInt64::MAX // 8_u64
      if outer_rows > max_count || inner_arrays > max_count || leaf_elements > max_count
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      if leaf_elements > UInt64::MAX // 9_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      leaf_bytes = leaf_elements * 9_u64
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(UInt64))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_nullable_numeric_materialized_bytes(
      values : WidePartArrayArrayNullableNumericArray,
      element_type : String,
    ) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(Nullable(T))) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(Nullable(T))) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      max_offset_count = UInt64::MAX // 8_u64
      bytes_per_leaf = (1 + WidePart.array_numeric_payload_width(element_type)).to_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_elements > UInt64::MAX // bytes_per_leaf
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * bytes_per_leaf
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(Nullable(T))) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def array_array_numeric_materialized_bytes(
      values : WidePartArrayArrayNumericArray,
      element_type : String,
    ) : UInt64
      outer_rows = values.size.to_u64
      inner_arrays = 0_u64
      leaf_elements = 0_u64
      values.each do |row|
        row_inner_arrays = row.size.to_u64
        if row_inner_arrays > WidePart::MAX_ARRAY_MARK_ELEMENTS - inner_arrays
          raise CorruptPartError.new("selected Array(Array(T)) inner-array count exceeds materialization limit")
        end
        inner_arrays += row_inner_arrays
        row.each do |inner|
          row_leaf_elements = inner.size.to_u64
          if row_leaf_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaf_elements
            raise CorruptPartError.new("selected Array(Array(T)) leaf element count exceeds materialization limit")
          end
          leaf_elements += row_leaf_elements
        end
      end

      width = WidePart.array_numeric_payload_width(element_type).to_u64
      max_offset_count = UInt64::MAX // 8_u64
      if outer_rows > max_offset_count || inner_arrays > max_offset_count || leaf_elements > UInt64::MAX // width
        raise CorruptPartError.new("selected Array(Array(T)) byte count overflows")
      end
      outer_bytes = outer_rows * 8_u64
      inner_bytes = inner_arrays * 8_u64
      leaf_bytes = leaf_elements * width
      if inner_bytes > UInt64::MAX - outer_bytes || leaf_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("selected Array(Array(T)) byte count overflows")
      end
      total_bytes = outer_bytes + inner_bytes + leaf_bytes
      if total_bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("selected Array(Array(T)) mark exceeds aggregate materialization limit")
      end
      total_bytes
    end

    private def validate_selected_part(requested_path : String) : {String, String, MergeTreePartInfo}
      raise BoundsError.new("part path is empty or exceeds limit") if requested_path.empty? || requested_path.bytesize > MAX_PART_PATH_BYTES
      path = File.expand_path(requested_path)
      name = File.basename(path)
      raise BoundsError.new("part name exceeds limit") if name.bytesize > MAX_PART_NAME_BYTES
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, name, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected part")
    end

    private def validate_projection_name(projection_name : String) : Nil
      if projection_name.bytesize > MAX_PART_NAME_BYTES - ".proj".bytesize
        raise BoundsError.new("projection child name exceeds limit")
      end
      unless /\A[A-Za-z0-9_]+\z/.matches?(projection_name)
        raise InvalidPartError.new("invalid projection name")
      end
    end

    private def validate_selected_projection_child(parent_path : String, projection_name : String) : String
      child_path = File.join(parent_path, "#{projection_name}.proj")
      raise BoundsError.new("projection child path exceeds limit") if child_path.bytesize > MAX_PART_PATH_BYTES
      name = File.basename(child_path)
      raise InvalidPartError.new("projection child is a symbolic link: #{name}") if File.symlink?(child_path)
      raise InvalidPartError.new("projection child is not a directory: #{name}") unless Dir.exists?(child_path)
      child_path
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected projection child")
    end

    private def reject_overlapping_parts(parts : Array({String, String, MergeTreePartInfo})) : Nil
      parts.each_with_index do |left, left_index|
        (left_index + 1...parts.size).each do |right_index|
          right = parts[right_index]
          if left[2].overlaps?(right[2])
            raise InvalidPartError.new("selected parts overlap: #{left[1]} and #{right[1]}")
          end
        end
      end
    end

    private def checked_total_rows(total : UInt64, rows : UInt64) : UInt64
      raise BoundsError.new("total row count exceeds limit") if rows > MAX_TOTAL_ROWS - total
      total + rows
    end

    private def checked_total_marks(total : UInt64, marks : UInt64) : UInt64
      raise BoundsError.new("total mark count exceeds limit") if marks > MAX_TOTAL_MARKS - total
      total + marks
    end
  end
end
