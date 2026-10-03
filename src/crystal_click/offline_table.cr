module CrystalClick
  # Read-only view of one table's parsed DDL and physical part candidates.
  class OfflineTable
    MAX_MATERIALIZED_VALUES_ROWS           = 100_000_u64
    MAX_MATERIALIZED_VALUES_STRING_BYTES   = 64_u64 * 1024 * 1024
    MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS = 1_000_000_u64
    MAX_MATERIALIZED_VALUES_TUPLE_CELLS    = 1_000_000_u64

    getter name : String
    getter engine : String
    getter primary_key_column : String?
    getter kind : Symbol

    @columns : Array(OfflineColumn)
    @part_candidates : Array(OfflinePartCandidate)?
    @uuid : String?
    @part_candidates_catalog : OfflineCatalog?
    @metadata_ddl : String?
    @projections : Array(OfflineProjection)

    def initialize(
      @name : String,
      @uuid : String?,
      @engine : String,
      @columns : Array(OfflineColumn),
      @part_candidates : Array(OfflinePartCandidate)?,
      @primary_key_column : String? = nil,
      @part_candidates_catalog : OfflineCatalog? = nil,
      @kind : Symbol = :table,
      metadata_ddl : String? = nil,
      projections : Array(OfflineProjection) = [] of OfflineProjection,
    )
      @metadata_ddl = metadata_ddl.try(&.dup)
      @projections = projections.map(&.copy)
    end

    def uuid : String
      raise UnsupportedFormatError.new("synthetic system table has no UUID") if @part_candidates_catalog
      value = @uuid || raise(UnsupportedFormatError.new("synthetic system table has no UUID"))
      value.dup
    end

    def columns : Array(OfflineColumn)
      @columns.dup
    end

    # Returns the exact bounded local metadata text when this object came from
    # an on-disk DDL file. The copy prevents callers from mutating catalog state.
    def metadata_ddl : String?
      @metadata_ddl.try(&.dup)
    end

    # Projection declarations are copied on both the collection and element
    # boundaries; their definitions remain opaque and are never executed.
    def projections : Array(OfflineProjection)
      @projections.map(&.copy)
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
      max_tuple_cells : UInt64 = MAX_MATERIALIZED_VALUES_TUPLE_CELLS,
    ) : Array(OfflineColumnValue)
      raise BoundsError.new("selected column row limit exceeds hard limit") if max_rows > MAX_MATERIALIZED_VALUES_ROWS
      raise BoundsError.new("selected column String payload limit exceeds hard limit") if max_string_bytes > MAX_MATERIALIZED_VALUES_STRING_BYTES
      raise BoundsError.new("selected column Tuple cell limit exceeds hard limit") if max_tuple_cells > MAX_MATERIALIZED_VALUES_TUPLE_CELLS

      if catalog = @part_candidates_catalog
        return catalog.part_candidates_values(column_name, max_rows, max_string_bytes)
      end
      reject_materialized_view_data_access!

      source_name, _source_type, selected_type, _json_path = resolve_typed_ddl_selection(column_name, allow_unsupported_exact: true)
      object_root = WidePart.json_type?(selected_type)
      unless object_root || WidePart.supports_typed_type?(selected_type) || WidePart.catalog_type(selected_type)
        raise UnsupportedFormatError.new("selected table column type is unsupported")
      end
      source_column = @columns.find { |entry| entry.name == source_name } || raise(CorruptPartError.new("selected column disappeared from table DDL"))
      raise UnsupportedFormatError.new("ALIAS columns cannot be materialized") if source_column.alias_column
      tuple_plan = WideTupleTypePlan.for_type(selected_type)

      expected_rows = 0_u64
      candidates = resolved_scan_parts
      candidates.each do |candidate|
        if expected_rows > max_rows || candidate.row_count > max_rows - expected_rows
          raise BoundsError.new("selected column materialization exceeds row limit")
        end
        expected_rows += candidate.row_count
      end

      if object_root
        return ObjectValuesMaterializer.materialize(self, candidates, column_name, selected_type, expected_rows, max_string_bytes, max_tuple_cells)
      end

      if plan = tuple_plan
        TupleValuesMaterializer.checked_expected_cells(expected_rows, plan.fields.size, max_tuple_cells)
      end
      if qbit_plan = QBitColumnType.for_type(selected_type)
        QBitValuesMaterializer.checked_expected_charge(expected_rows, qbit_plan)
      end
      if point_plan = PointColumnType.for_type(selected_type)
        PointValuesMaterializer.checked_expected_charge(expected_rows, point_plan)
      end
      if GeoArrayColumnType.for_type(selected_type)
        return GeoArrayValuesMaterializer.materialize(self, candidates, column_name, selected_type, expected_rows)
      end
      if GeometryColumnType.for_type(selected_type)
        return GeometryValuesMaterializer.materialize(self, candidates, column_name, selected_type, expected_rows)
      end
      values = Array(OfflineColumnValue).new(expected_rows.to_i)
      observed_rows = 0_u64
      string_bytes = 0_u64
      array_elements = [0_u64]
      tuple_cells = [0_u64]

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
            tuple_cells,
            expected_rows,
            max_string_bytes,
            max_tuple_cells
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
      tuple_cells : Array(UInt64),
      expected_rows : UInt64,
      max_string_bytes : UInt64,
      max_tuple_cells : UInt64,
    ) : {UInt64, UInt64}
      if PointColumnType.for_type(selected_type)
        observed_rows = PointValuesMaterializer.append_values(
          values,
          batch,
          column_name,
          observed_rows,
          expected_rows
        )
        return {observed_rows, string_bytes}
      end

      if qbit_plan = QBitColumnType.for_type(selected_type)
        if qbit_plan.nullable
          observed_rows = append_materialized_values(values, batch.nullable_qbits_for(column_name), observed_rows, expected_rows)
        else
          observed_rows = append_materialized_values(values, batch.qbits_for(column_name), observed_rows, expected_rows)
        end
        return {observed_rows, string_bytes}
      end

      if array_tuple_plan = WideArrayTupleTypePlan.for_type(selected_type)
        if WideTypePlan.admitted(selected_type).nil?
          observed_rows, array_elements[0], tuple_cells[0], string_bytes = ArrayTupleValuesMaterializer.append_rows(
            values,
            batch,
            column_name,
            observed_rows,
            expected_rows,
            array_elements[0],
            tuple_cells[0],
            string_bytes,
            max_string_bytes,
            max_tuple_cells,
            array_tuple_plan.tuple_plan.fields.size
          )
          return {observed_rows, string_bytes}
        end
      end

      if map_tuple_plan = WideMapTupleTypePlan.for_type(selected_type)
        if WideTypePlan.admitted(selected_type).nil?
          observed_rows, array_elements[0], tuple_cells[0], string_bytes = MapTupleValuesMaterializer.append_rows(
            values,
            batch,
            column_name,
            map_tuple_plan.column_type,
            map_tuple_plan.tuple_plan.type_name,
            map_tuple_plan.key_type.base_type_name == "String" || map_tuple_plan.key_type.parameterized_type.is_a?(WideTupleFixedStringType),
            observed_rows,
            expected_rows,
            array_elements[0],
            tuple_cells[0],
            string_bytes,
            max_string_bytes,
            max_tuple_cells,
            map_tuple_plan.tuple_plan.fields.size
          )
          return {observed_rows, string_bytes}
        end
      end

      if tuple_plan = WideTupleTypePlan.for_type(selected_type)
        # Keep the long-standing exact pair value shape and accessor path;
        # other admitted W94 profiles use owned row handles without arity
        # proliferation in OfflineColumnValue.
        unless WidePart.supports_tuple_uint64_string_type?(selected_type)
          return TupleValuesMaterializer.append_rows(
            values,
            batch,
            column_name,
            observed_rows,
            expected_rows,
            string_bytes,
            max_string_bytes,
            tuple_plan.fields.size
          )
        end
      end

      if shape = WidePart.array_map_array_leaf_shape(selected_type)
        observed_rows, array_elements[0], string_bytes = append_materialized_array_map_array_leaf_for_shape(
          values,
          batch,
          column_name,
          shape,
          observed_rows,
          expected_rows,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
        return {observed_rows, string_bytes}
      end

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
      elsif selected_type == "BFloat16"
        observed_rows = append_materialized_values(values, batch.bfloat16s_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Nullable(BFloat16)"
        observed_rows = append_materialized_values(values, batch.nullable_bfloat16s_for(column_name), observed_rows, expected_rows)
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
      elsif selected_type == "Int128"
        observed_rows = append_materialized_values(values, batch.int128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "UInt128"
        observed_rows = append_materialized_values(values, batch.uint128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Int256"
        observed_rows = append_materialized_values(values, batch.int256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "UInt256"
        observed_rows = append_materialized_values(values, batch.uint256_raw_for(column_name), observed_rows, expected_rows)
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
      elsif selected_type == "Nullable(Int128)"
        observed_rows = append_materialized_values(values, batch.nullable_int128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Nullable(UInt128)"
        observed_rows = append_materialized_values(values, batch.nullable_uint128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Nullable(Int256)"
        observed_rows = append_materialized_values(values, batch.nullable_int256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif selected_type == "Nullable(UInt256)"
        observed_rows = append_materialized_values(values, batch.nullable_uint256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal128_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal128_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      elsif !WidePart.nullable_decimal256_scale(selected_type).nil?
        observed_rows = append_materialized_values(values, batch.nullable_decimal256_raw_for(column_name), observed_rows, expected_rows)
        return {observed_rows, string_bytes}
      end

      if element_type = WidePart.array_array_nullable_time_element_type(selected_type)
        selected_rows = array_array_nullable_time_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_nullable_time_values(values, batch, column_name, element_type, array_elements[0])
        return {observed_rows, string_bytes}
      elsif element_type = WidePart.array_array_time_element_type(selected_type)
        selected_rows = array_array_time_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_time_values(values, batch, column_name, element_type, array_elements[0])
        return {observed_rows, string_bytes}
      elsif element_type = WidePart.array_array_nullable_temporal_element_type(selected_type)
        selected_rows = array_array_nullable_temporal_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_nullable_temporal_values(values, batch, column_name, element_type, array_elements[0])
        return {observed_rows, string_bytes}
      elsif element_type = WidePart.array_array_temporal_element_type(selected_type)
        selected_rows = array_array_temporal_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_temporal_values(values, batch, column_name, element_type, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_decimal32_scale(selected_type).nil?
        selected_values = batch.array_array_decimal32_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_decimal64_scale(selected_type).nil?
        selected_values = batch.array_array_decimal64_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_decimal128_scale(selected_type).nil?
        selected_values = batch.array_array_decimal128_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_decimal256_scale(selected_type).nil?
        selected_values = batch.array_array_decimal256_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_nullable_decimal32_scale(selected_type).nil?
        selected_values = batch.array_array_nullable_decimal32_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_nullable_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_nullable_decimal64_scale(selected_type).nil?
        selected_values = batch.array_array_nullable_decimal64_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_nullable_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_nullable_decimal128_scale(selected_type).nil?
        selected_values = batch.array_array_nullable_decimal128_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_nullable_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif !WidePart.array_array_nullable_decimal256_scale(selected_type).nil?
        selected_values = batch.array_array_nullable_decimal256_raw_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_nullable_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif WidePart.array_enum8_codes(selected_type)
        selected_values = batch.array_enum8_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif WidePart.array_nullable_enum8_codes(selected_type)
        selected_values = batch.array_nullable_enum8_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif WidePart.array_enum16_codes(selected_type)
        selected_values = batch.array_enum16_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
        return {observed_rows, string_bytes}
      elsif WidePart.array_nullable_enum16_codes(selected_type)
        selected_values = batch.array_nullable_enum16_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
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
      when "Time"
        observed_rows = append_time_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when "Date32"
        observed_rows = append_date32_codes_values(values, batch, column_name, observed_rows, expected_rows)
      when "DateTime"
        observed_rows = append_datetime_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("DateTime('")
        observed_rows = append_datetime_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when "Int64"
        observed_rows = append_int64_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("DateTime64(")
        unless WidePart.datetime64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_datetime64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("Time64(")
        unless WidePart.time64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_time64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
      when "Float32"
        observed_rows = append_float32_values(values, batch, column_name, observed_rows, expected_rows)
      when "Float64"
        observed_rows = append_float64_values(values, batch, column_name, observed_rows, expected_rows)
      when "Array(UInt64)"
        selected_values = batch.array_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_uint64s(values, selected_values, array_elements[0])
      when "Array(UUID)"
        selected_values = batch.array_uuids_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(IPv4)"
        selected_values = batch.array_ipv4s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(IPv6)"
        selected_values = batch.array_ipv6s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Date)"
        selected_values = batch.array_date_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Date32)"
        selected_values = batch.array_date32_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(DateTime)"
        selected_values = batch.array_datetime_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(DateTime('")
        selected_values = batch.array_datetime_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Time)"
        selected_values = batch.array_time_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(DateTime64(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.array_datetime64_scale(selected_type)
        selected_values = batch.array_datetime64_ticks_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Time64(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.array_time64_scale(selected_type)
        selected_values = batch.array_time64_ticks_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Decimal(")
        descriptor = DecimalColumnType.parse(selected_type) || raise(UnsupportedFormatError.new("selected table column type is unsupported"))
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless descriptor.shape == DecimalColumnShape::Array
        array_elements[0] = case descriptor.storage_width
                            when 4
                              selected_values = batch.array_decimal32_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_numeric(values, selected_values, array_elements[0])
                            when 8
                              selected_values = batch.array_decimal64_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_numeric(values, selected_values, array_elements[0])
                            when 16
                              selected_values = batch.array_decimal128_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_numeric(values, selected_values, array_elements[0])
                            when 32
                              selected_values = batch.array_decimal256_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_numeric(values, selected_values, array_elements[0])
                            else
                              raise UnsupportedFormatError.new("selected table Decimal width is unsupported")
                            end
      when "Array(UInt8)"
        selected_values = batch.array_numeric_values(column_name, UInt8)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(UInt16)"
        selected_values = batch.array_numeric_values(column_name, UInt16)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(BFloat16)"
        selected_values = batch.array_bfloat16s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(UInt32)"
        selected_values = batch.array_numeric_values(column_name, UInt32)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int8)"
        selected_values = batch.array_numeric_values(column_name, Int8)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int16)"
        selected_values = batch.array_numeric_values(column_name, Int16)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int32)"
        selected_values = batch.array_numeric_values(column_name, Int32)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int64)"
        selected_values = batch.array_numeric_values(column_name, Int64)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Float32)"
        selected_values = batch.array_numeric_values(column_name, Float32)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Float64)"
        selected_values = batch.array_numeric_values(column_name, Float64)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int128)"
        selected_values = batch.array_numeric_values(column_name, Int128)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(UInt128)"
        selected_values = batch.array_numeric_values(column_name, UInt128)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Int256)"
        selected_values = batch.array_numeric_values(column_name, Int256Value)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(UInt256)"
        selected_values = batch.array_numeric_values(column_name, UInt256Value)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_numeric(values, selected_values, array_elements[0])
      when "Array(Bool)"
        selected_values = batch.array_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_bool(values, selected_values, array_elements[0])
      when "Array(Nullable(String))"
        selected_values = batch.array_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_nullable_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when .starts_with?("Array(Nullable(FixedString(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.array_nullable_fixed_string_width(selected_type)
        selected_values = batch.array_nullable_fixed_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_nullable_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Array(Nullable(Bool))"
        selected_values = batch.array_nullable_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_bool(values, selected_values, array_elements[0])
      when "Array(Nullable(Date))"
        selected_values = batch.array_nullable_date_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(Date32))"
        selected_values = batch.array_nullable_date32_codes_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(DateTime))"
        selected_values = batch.array_nullable_datetime_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Nullable(DateTime('")
        selected_values = batch.array_nullable_datetime_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(Time))"
        selected_values = batch.array_nullable_time_seconds_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(UUID))"
        selected_values = batch.array_nullable_uuids_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(IPv4))"
        selected_values = batch.array_nullable_ipv4s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Nullable(IPv6))"
        selected_values = batch.array_nullable_ipv6s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Nullable(Decimal(")
        descriptor = DecimalColumnType.parse(selected_type) || raise(UnsupportedFormatError.new("selected table column type is unsupported"))
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless descriptor.shape == DecimalColumnShape::ArrayNullable
        array_elements[0] = case descriptor.storage_width
                            when 4
                              selected_values = batch.array_nullable_decimal32_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
                            when 8
                              selected_values = batch.array_nullable_decimal64_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
                            when 16
                              selected_values = batch.array_nullable_decimal128_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
                            when 32
                              selected_values = batch.array_nullable_decimal256_raw_for(column_name)
                              observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
                              append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
                            else
                              raise UnsupportedFormatError.new("selected table Decimal width is unsupported")
                            end
      when .starts_with?("Array(Nullable(DateTime64(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.nullable_array_datetime64_scale(selected_type)
        selected_values = batch.array_nullable_datetime64_ticks_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Nullable(Time64(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.nullable_array_time64_scale(selected_type)
        selected_values = batch.array_nullable_time64_ticks_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when .starts_with?("Array(Nullable(")
        element_type = WidePart.nullable_numeric_array_element_type(selected_type) || raise(UnsupportedFormatError.new("selected table column type is unsupported"))
        selected_values = array_nullable_numeric_values_for(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_numeric(values, selected_values, array_elements[0])
      when "Array(Array(UInt64))"
        selected_values = batch.array_array_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_uint64s(values, selected_values, array_elements[0])
      when "Array(Array(String))"
        selected_values = batch.array_array_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_array_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Array(Array(Nullable(String)))"
        selected_values = batch.array_array_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_array_nullable_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Array(Array(Nullable(UInt64)))"
        selected_values = batch.array_array_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_array_nullable_uint64s(values, selected_values, array_elements[0])
      when .starts_with?("Array(Array(Nullable(")
        element_type = WidePart.array_array_nullable_numeric_element_type(selected_type) || raise(UnsupportedFormatError.new("selected table column type is unsupported"))
        selected_rows = array_array_nullable_numeric_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_nullable_numeric_values(values, batch, column_name, element_type, array_elements[0])
      when .starts_with?("Array(Array(")
        element_type = WidePart.array_array_numeric_element_type(selected_type) || raise(UnsupportedFormatError.new("selected table column type is unsupported"))
        selected_rows = array_array_numeric_row_count(batch, column_name, element_type)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_rows, expected_rows)
        array_elements[0] = append_array_array_numeric_values(values, batch, column_name, element_type, array_elements[0])
      when "Array(Nullable(UInt64))"
        selected_values = batch.array_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_array_nullable_uint64s(values, selected_values, array_elements[0])
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
      when WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
        selected_values = batch.array_tuple_uint64_string_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_tuple_uint64_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING
        selected_values = batch.array_tuple_nullable_uint64_string_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_tuple_nullable_uint64_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_UINT64
        selected_values = batch.array_tuple_uint64_uint64_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_map_uint64_values(
          values,
          selected_values,
          array_elements[0]
        )
      when .starts_with?("Array(FixedString(")
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.array_fixed_string_width(selected_type)
        selected_values = batch.array_fixed_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_strings(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Tuple(a UInt64, b String)"
        selected_values = batch.tuples_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        selected_values.each do |number, string_value|
          string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
          values << {number, String.new(string_value.to_slice)}
        end
      when "Map(UInt64, String)"
        selected_values = batch.map_uint64_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_map_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(UInt64, UInt64)"
        selected_values = batch.map_uint64_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_map_uint64_values(values, selected_values, array_elements[0])
      when "Map(UInt64, UInt8)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, UInt8, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, UInt16)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, UInt16, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, UInt32)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, UInt32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Int8)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Int8, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Int16)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Int16, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Int32)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Int32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Int64)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Int64, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Float32)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Float32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Float64)"
        observed_rows = append_materialized_uint64_numeric_map_batch(values, batch, column_name, Float64, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(UInt64))"
        selected_values = batch.map_uint64_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_map_nullable_uint64_values(values, selected_values, array_elements[0])
      when "Map(UInt64, Nullable(UInt8))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, UInt8, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(UInt16))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, UInt16, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(UInt32))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, UInt32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Int8))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Int8, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Int16))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Int16, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Int32))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Int32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Int64))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Int64, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Float32))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Float32, observed_rows, expected_rows, array_elements)
      when "Map(UInt64, Nullable(Float64))"
        observed_rows = append_materialized_uint64_nullable_numeric_map_batch(values, batch, column_name, Float64, observed_rows, expected_rows, array_elements)
      when "Map(String, UInt64)"
        selected_values = batch.map_string_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_uint64_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, UInt8)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, UInt8, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, UInt16)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, UInt16, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, UInt32)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, UInt32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Int8)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Int8, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Int16)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Int16, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Int32)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Int32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Int64)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Int64, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Float32)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Float32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Float64)"
        observed_rows, string_bytes = append_materialized_string_numeric_map_batch(values, batch, column_name, Float64, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Array(Map(String, UInt64))"
        selected_values = batch.array_map_string_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_string_uint64_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Array(Map(UInt64, String))"
        selected_values = batch.array_map_uint64_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_string_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(String, String))"
        selected_values = batch.array_map_string_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_string_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(UInt64, Nullable(String)))"
        selected_values = batch.array_map_uint64_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_string_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(String, Nullable(String)))"
        selected_values = batch.array_map_string_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_string_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(UInt64, Bool))"
        selected_values = batch.array_map_uint64_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_bool_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(String, Bool))"
        selected_values = batch.array_map_string_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_bool_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(UInt64, Nullable(Bool)))"
        selected_values = batch.array_map_uint64_nullable_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_bool_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when "Array(Map(String, Nullable(Bool)))"
        selected_values = batch.array_map_string_nullable_bools_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_array_map_bool_leaf_values(
          values, selected_values, array_elements[0], string_bytes, max_string_bytes
        )
      when .starts_with?("Array(Map(")
        leaf_type = WidePart.array_map_uint64_numeric_value_type(selected_type) ||
                    WidePart.array_map_string_numeric_value_type(selected_type) ||
                    WidePart.array_map_uint64_nullable_numeric_value_type(selected_type) ||
                    WidePart.array_map_string_nullable_numeric_value_type(selected_type) ||
                    raise(UnsupportedFormatError.new("selected Array(Map) leaf is not an admitted primitive numeric type"))
        string_keys = !WidePart.array_map_string_numeric_value_type(selected_type).nil? ||
                      !WidePart.array_map_string_nullable_numeric_value_type(selected_type).nil?
        nullable_values = !WidePart.array_map_uint64_nullable_numeric_value_type(selected_type).nil? ||
                          !WidePart.array_map_string_nullable_numeric_value_type(selected_type).nil?
        observed_rows, array_elements[0], string_bytes = append_materialized_array_map_numeric_for_type(
          values,
          batch,
          column_name,
          leaf_type,
          string_keys,
          nullable_values,
          observed_rows,
          expected_rows,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Array(UInt64))"
        selected_values = batch.map_string_array_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_array_uint64_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(UInt64, Array(UInt64))"
        selected_values = batch.map_uint64_array_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_uint64_key_map_array_uint64_values(values, selected_values, array_elements[0])
      when "Map(String, Array(String))"
        selected_values = batch.map_string_array_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_array_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(UInt64, Array(String))"
        selected_values = batch.map_uint64_array_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_uint64_key_map_array_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Array(Nullable(UInt64)))"
        selected_values = batch.map_string_array_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_array_nullable_uint64_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Array(Nullable(String)))"
        selected_values = batch.map_string_array_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_array_nullable_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(UInt64, Array(Nullable(UInt64)))"
        selected_values = batch.map_uint64_array_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0] = append_materialized_uint64_key_map_array_nullable_uint64_values(
          values,
          selected_values,
          array_elements[0]
        )
      when "Map(UInt64, Array(Nullable(String)))"
        selected_values = batch.map_uint64_array_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_uint64_key_map_array_nullable_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when .starts_with?("Map(UInt64, Array(Nullable("), .starts_with?("Map(String, Array(Nullable(")
        leaf_type = WidePart.map_uint64_array_nullable_numeric_value_type(selected_type) ||
                    WidePart.map_string_array_nullable_numeric_value_type(selected_type) ||
                    raise(UnsupportedFormatError.new("selected Map Array leaf is not an admitted nullable primitive numeric type"))
        string_keys = !WidePart.map_string_array_nullable_numeric_value_type(selected_type).nil?
        observed_rows, array_elements[0], string_bytes = append_materialized_nullable_numeric_map_array_for_type(
          values, batch, column_name, leaf_type, string_keys, observed_rows,
          expected_rows, array_elements[0], string_bytes, max_string_bytes
        )
      when .starts_with?("Map(UInt64, Array("), .starts_with?("Map(String, Array(")
        leaf_type = WidePart.map_uint64_array_numeric_value_type(selected_type) ||
                    WidePart.map_string_array_numeric_value_type(selected_type) ||
                    raise(UnsupportedFormatError.new("selected Map Array leaf is not an admitted primitive numeric type"))
        string_keys = !WidePart.map_string_array_numeric_value_type(selected_type).nil?
        observed_rows, array_elements[0], string_bytes = append_materialized_numeric_map_array_for_type(
          values, batch, column_name, leaf_type, string_keys, observed_rows,
          expected_rows, array_elements[0], string_bytes, max_string_bytes
        )
      when "Map(String, String)"
        selected_values = batch.map_string_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_map_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Nullable(UInt64))"
        selected_values = batch.map_string_nullable_uint64s_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_nullable_uint64_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Nullable(UInt8))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, UInt8, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(UInt16))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, UInt16, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(UInt32))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, UInt32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Int8))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Int8, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Int16))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Int16, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Int32))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Int32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Int64))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Int64, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Float32))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Float32, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(String, Nullable(Float64))"
        observed_rows, string_bytes = append_materialized_string_nullable_numeric_map_batch(values, batch, column_name, Float64, observed_rows, expected_rows, string_bytes, max_string_bytes, array_elements)
      when "Map(UInt64, Nullable(String))"
        selected_values = batch.map_uint64_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_map_nullable_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Map(String, Nullable(String))"
        selected_values = batch.map_string_nullable_strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        array_elements[0], string_bytes = append_materialized_string_key_map_nullable_string_values(
          values,
          selected_values,
          array_elements[0],
          string_bytes,
          max_string_bytes
        )
      when "Dynamic"
        if batch.dynamic_string_uint64_profile?(column_name)
          selected_values = batch.dynamic_string_uint64_for(column_name)
          observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
          selected_values.each do |value|
            if string_value = value.as?(String)
              string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
              values << String.new(string_value.to_slice)
            else
              values << value
            end
          end
        else
          selected_values = batch.dynamic_strings_for(column_name)
          observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
          string_bytes = append_materialized_strings(values, selected_values, string_bytes, max_string_bytes)
        end
      when "String"
        selected_values = batch.strings_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        string_bytes = append_materialized_strings(values, selected_values, string_bytes, max_string_bytes)
      when WideVariantStringUInt64TypePlan::TYPE
        selected_values = batch.variant_string_uint64_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        selected_values.each do |value|
          if string_value = value.as?(String)
            string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
            values << String.new(string_value.to_slice)
          else
            values << value
          end
        end
      when WideVariantBoolStringUInt64TypePlan::TYPE
        selected_values = batch.variant_bool_string_uint64_for(column_name)
        observed_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
        selected_values.each do |value|
          if string_value = value.as?(String)
            string_bytes = checked_materialized_value_string_bytes(string_bytes, string_value.bytesize.to_u64, max_string_bytes)
            values << String.new(string_value.to_slice)
          else
            values << value
          end
        end
      when "LowCardinality(String)"
        selected_values = batch.low_cardinality_strings_for(column_name)
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
      when .starts_with?("Nullable(DateTime('")
        observed_rows = append_nullable_datetime_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when "Nullable(Time)"
        observed_rows = append_nullable_time_seconds_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("Nullable(DateTime64(")
        unless WidePart.nullable_datetime64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_nullable_datetime64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
      when .starts_with?("Nullable(Time64(")
        unless WidePart.nullable_time64_scale(selected_type)
          raise UnsupportedFormatError.new("selected table column type is unsupported")
        end
        observed_rows = append_nullable_time64_ticks_values(values, batch, column_name, observed_rows, expected_rows)
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
      reject_materialized_view_data_access!
      candidates = @part_candidates
      raise UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only") unless candidates
      candidates.dup
    end

    private def reject_materialized_view_data_access! : Nil
      if @kind == :materialized_view
        raise UnsupportedFormatError.new("materialized view is metadata-only; direct part inventory and row scans are unsupported")
      end
    end

    # Resolve the physical inventory to a deterministic, unambiguous set of
    # maximal covering parts for an offline scan. This is an inferred scan
    # set, not ClickHouse server Active state.
    def resolved_scan_parts : Array(OfflinePartCandidate)
      reject_materialized_view_data_access!
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
      reject_materialized_view_data_access!
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
      reject_materialized_view_data_access!
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
        unless column.type == "UInt64" || QBitColumnType.for_type(column.type)
          raise UnsupportedFormatError.new("selected table column is neither UInt64 nor canonical QBit")
        end
      end

      key_column = @primary_key_column || raise(UnsupportedFormatError.new("table does not have a supported simple ascending UInt64 ORDER BY key"))
      raise UnsupportedFormatError.new("selected columns must include the ORDER BY key") unless selected.includes?(key_column)

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      reader = WidePartTable.open_selected_typed(candidates.map(&.path), columns)
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
        index = PrimaryKeyIndex.open(candidate.path, part_mark_rows[part_index].size, checksums, verify_recorded_hash: true)
        candidate_marks << index.candidate_marks(lower_bound, upper_bound)
      end
      reader.scan_typed_candidate_marks(candidate_marks, &block)
    end

    # Scan selected exact primitive numeric columns. The type declared by the
    # table DDL must exactly match each selected part's columns.txt type.
    def scan_numeric(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      reject_materialized_view_data_access!
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

    # Scan only exact canonical QBit and Nullable(QBit) columns through the
    # shared typed reader. Table-DDL/part matching is checked before callbacks.
    def scan_qbit(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      columns.each do |column_name|
        _source_name, _source_type, selected_type, _json_path = resolve_typed_ddl_selection(column_name)
        unless QBitColumnType.for_type(selected_type)
          raise UnsupportedFormatError.new("scan_qbit requires exact canonical QBit columns")
        end
      end
      if reader = open_typed_reader(columns, batch_rows, "QBit batch")
        reader.scan_typed(batch_rows: batch_rows, &block)
      end
    end

    # Scan the physical child parts for one explicitly declared projection.
    # This does not execute its SELECT or choose an optimizer plan. Every
    # resolved parent must have a present child with preflighted selected
    # metadata and stream sizes before the first callback; selected columns
    # are interpreted from each child's physical schema during the scan.
    def scan_projection_typed(
      projection_name : String,
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      reject_materialized_view_data_access!
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      if projection_name.bytesize > WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
        raise BoundsError.new("projection child name exceeds limit")
      end
      unless /\A[A-Za-z0-9_]+\z/.matches?(projection_name)
        raise InvalidPartError.new("invalid projection name: #{projection_name}")
      end
      unless @projections.any? { |projection| projection.name == projection_name }
        raise UnsupportedFormatError.new("selected projection is not declared by table DDL")
      end
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name
      end

      candidates = resolved_scan_parts
      return nil if candidates.empty?

      # The projection factory preflights child coverage and the selected
      # physical schemas/checksums across the complete resolved parent set.
      # Deliberately do not compare its column types with the base-table DDL.
      reader = WidePartTable.open_selected_projection_typed(candidates.map(&.path), projection_name, columns)
      reader.scan_typed(batch_rows: batch_rows, &block)
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
      reject_materialized_view_data_access!
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

    private def append_time_seconds_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.time_seconds_for(column_name), observed_rows, expected_rows)
    end

    private def append_time64_ticks_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.time64_ticks_for(column_name), observed_rows, expected_rows)
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

    private def append_nullable_time_seconds_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_time_seconds_for(column_name), observed_rows, expected_rows)
    end

    private def append_nullable_time64_ticks_values(values : Array(OfflineColumnValue), batch : WidePartTableBatch, column_name : String, observed_rows : UInt64, expected_rows : UInt64) : UInt64
      append_materialized_values(values, batch.nullable_time64_ticks_for(column_name), observed_rows, expected_rows)
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

    private def append_materialized_array_numeric(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(T)),
      observed_elements : UInt64,
    ) : UInt64 forall T
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each { |row| values << row.dup }
      next_elements
    end

    private def append_materialized_array_bool(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Bool)),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end
      selected_values.each { |row| values << row.dup }
      next_elements
    end

    private def append_materialized_array_nullable_bool(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Bool?)),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end
      selected_values.each { |row| values << row.dup }
      next_elements
    end

    private def append_materialized_array_array_uint64s(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(UInt64))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        # Bound both nested-array objects and leaf slots. Empty inner arrays
        # consume structural capacity even though they have no UInt64 payload.
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(UInt64)).new(row.size)
        row.each { |inner| owned_row << inner.dup }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_array_array_nullable_uint64s(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(UInt64?))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        # Bound both inner-array objects and leaf slots before making caller-owned copies.
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(UInt64?)).new(row.size)
        row.each { |inner| owned_row << inner.dup }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_array_array_nullable_numeric(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(T?))),
      observed_elements : UInt64,
    ) : UInt64 forall T
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(T?)).new(row.size)
        row.each { |inner| owned_row << inner.dup }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_array_array_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(String))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        # Count inner arrays as well as leaf string slots before allocating
        # catalog-owned copies; empty inner arrays still consume capacity.
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
          inner.each do |value|
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(String)).new(row.size)
        row.each do |inner|
          owned_inner = Array(String).new(inner.size)
          inner.each { |value| owned_inner << String.new(value.to_slice) }
          owned_row << owned_inner
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_array_nullable_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(String?))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        # Count inner arrays and every nullable leaf slot before copying the
        # catalog-owned values; empty inner arrays still consume capacity.
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
          inner.each do |value|
            next unless string_value = value
            next_bytes = checked_materialized_value_string_bytes(next_bytes, string_value.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(String?)).new(row.size)
        row.each do |inner|
          owned_inner = Array(String?).new(inner.size)
          inner.each do |value|
            if string_value = value
              owned_inner << String.new(string_value.to_slice)
            else
              owned_inner << nil
            end
          end
          owned_row << owned_inner
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_array_numeric(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(T))),
      observed_elements : UInt64,
    ) : UInt64 forall T
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |inner|
          next_elements = checked_materialized_value_array_elements(next_elements, inner.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(T)).new(row.size)
        row.each { |inner| owned_row << inner.dup }
        values << owned_row
      end
      next_elements
    end

    private def array_array_numeric_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      case element_type
      when "UInt8"    then batch.array_array_numeric_values(column, UInt8).size.to_u64
      when "UInt16"   then batch.array_array_numeric_values(column, UInt16).size.to_u64
      when "UInt32"   then batch.array_array_numeric_values(column, UInt32).size.to_u64
      when "UInt64"   then batch.array_array_numeric_values(column, UInt64).size.to_u64
      when "Int8"     then batch.array_array_numeric_values(column, Int8).size.to_u64
      when "Int16"    then batch.array_array_numeric_values(column, Int16).size.to_u64
      when "Int32"    then batch.array_array_numeric_values(column, Int32).size.to_u64
      when "Int64"    then batch.array_array_numeric_values(column, Int64).size.to_u64
      when "Float32"  then batch.array_array_numeric_values(column, Float32).size.to_u64
      when "Float64"  then batch.array_array_numeric_values(column, Float64).size.to_u64
      when "Int128"   then batch.array_array_numeric_values(column, Int128).size.to_u64
      when "UInt128"  then batch.array_array_numeric_values(column, UInt128).size.to_u64
      when "Int256"   then batch.array_array_numeric_values(column, Int256Value).size.to_u64
      when "UInt256"  then batch.array_array_numeric_values(column, UInt256Value).size.to_u64
      when "BFloat16" then batch.array_array_numeric_values(column, BFloat16Value).size.to_u64
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(T)) numeric leaf type")
      end
    end

    private def array_array_nullable_numeric_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      case element_type
      when "UInt8"    then batch.array_array_nullable_numeric_values(column, UInt8).size.to_u64
      when "UInt16"   then batch.array_array_nullable_numeric_values(column, UInt16).size.to_u64
      when "UInt32"   then batch.array_array_nullable_numeric_values(column, UInt32).size.to_u64
      when "UInt64"   then batch.array_array_nullable_numeric_values(column, UInt64).size.to_u64
      when "Int8"     then batch.array_array_nullable_numeric_values(column, Int8).size.to_u64
      when "Int16"    then batch.array_array_nullable_numeric_values(column, Int16).size.to_u64
      when "Int32"    then batch.array_array_nullable_numeric_values(column, Int32).size.to_u64
      when "Int64"    then batch.array_array_nullable_numeric_values(column, Int64).size.to_u64
      when "Float32"  then batch.array_array_nullable_numeric_values(column, Float32).size.to_u64
      when "Float64"  then batch.array_array_nullable_numeric_values(column, Float64).size.to_u64
      when "Int128"   then batch.array_array_nullable_numeric_values(column, Int128).size.to_u64
      when "UInt128"  then batch.array_array_nullable_numeric_values(column, UInt128).size.to_u64
      when "Int256"   then batch.array_array_nullable_numeric_values(column, Int256Value).size.to_u64
      when "UInt256"  then batch.array_array_nullable_numeric_values(column, UInt256Value).size.to_u64
      when "BFloat16" then batch.array_array_nullable_numeric_values(column, BFloat16Value).size.to_u64
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric leaf type")
      end
    end

    private def array_array_temporal_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      case element_type
      when "Date"   then batch.array_array_date_codes_for(column).size.to_u64
      when "Date32" then batch.array_array_date32_codes_for(column).size.to_u64
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          batch.array_array_datetime_seconds_for(column).size.to_u64
        when DateTimeColumnType::Family::DateTime64
          batch.array_array_datetime64_ticks_for(column).size.to_u64
        else
          raise UnsupportedFormatError.new("unsupported nested temporal Array leaf type")
        end
      end
    end

    private def array_array_time_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      if element_type == "Time"
        batch.array_array_time_seconds_for(column).size.to_u64
      elsif WidePart.time64_scale(element_type)
        batch.array_array_time64_ticks_for(column).size.to_u64
      else
        raise UnsupportedFormatError.new("unsupported nested Time Array leaf type")
      end
    end

    private def array_array_nullable_time_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      if element_type == "Time"
        batch.array_array_nullable_time_seconds_for(column).size.to_u64
      elsif WidePart.time64_scale(element_type)
        batch.array_array_nullable_time64_ticks_for(column).size.to_u64
      else
        raise UnsupportedFormatError.new("unsupported nested nullable Time Array leaf type")
      end
    end

    private def append_array_array_time_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      if element_type == "Time"
        append_materialized_array_array_numeric(values, batch.array_array_time_seconds_for(column), observed_elements)
      elsif WidePart.time64_scale(element_type)
        append_materialized_array_array_numeric(values, batch.array_array_time64_ticks_for(column), observed_elements)
      else
        raise UnsupportedFormatError.new("unsupported nested Time Array leaf type")
      end
    end

    private def append_array_array_nullable_time_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      if element_type == "Time"
        append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_time_seconds_for(column), observed_elements)
      elsif WidePart.time64_scale(element_type)
        append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_time64_ticks_for(column), observed_elements)
      else
        raise UnsupportedFormatError.new("unsupported nested nullable Time Array leaf type")
      end
    end

    private def array_array_nullable_temporal_row_count(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : UInt64
      case element_type
      when "Date"   then batch.array_array_nullable_date_codes_for(column).size.to_u64
      when "Date32" then batch.array_array_nullable_date32_codes_for(column).size.to_u64
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          batch.array_array_nullable_datetime_seconds_for(column).size.to_u64
        when DateTimeColumnType::Family::DateTime64
          batch.array_array_nullable_datetime64_ticks_for(column).size.to_u64
        else
          raise UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type")
        end
      end
    end

    private def append_array_array_temporal_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      case element_type
      when "Date"   then append_materialized_array_array_numeric(values, batch.array_array_date_codes_for(column), observed_elements)
      when "Date32" then append_materialized_array_array_numeric(values, batch.array_array_date32_codes_for(column), observed_elements)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          append_materialized_array_array_numeric(values, batch.array_array_datetime_seconds_for(column), observed_elements)
        when DateTimeColumnType::Family::DateTime64
          append_materialized_array_array_numeric(values, batch.array_array_datetime64_ticks_for(column), observed_elements)
        else
          raise UnsupportedFormatError.new("unsupported nested temporal Array leaf type")
        end
      end
    end

    private def append_array_array_nullable_temporal_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      case element_type
      when "Date"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_date_codes_for(column), observed_elements)
      when "Date32" then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_date32_codes_for(column), observed_elements)
      else
        datetime_type = DateTimeColumnType.parse_leaf(element_type) || raise(UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type"))
        case datetime_type.family
        when DateTimeColumnType::Family::DateTime
          append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_datetime_seconds_for(column), observed_elements)
        when DateTimeColumnType::Family::DateTime64
          append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_datetime64_ticks_for(column), observed_elements)
        else
          raise UnsupportedFormatError.new("unsupported nested nullable temporal Array leaf type")
        end
      end
    end

    private def append_array_array_nullable_numeric_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      case element_type
      when "UInt8"    then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt8), observed_elements)
      when "UInt16"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt16), observed_elements)
      when "UInt32"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt32), observed_elements)
      when "UInt64"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt64), observed_elements)
      when "Int8"     then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int8), observed_elements)
      when "Int16"    then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int16), observed_elements)
      when "Int32"    then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int32), observed_elements)
      when "Int64"    then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int64), observed_elements)
      when "Float32"  then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Float32), observed_elements)
      when "Float64"  then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Float64), observed_elements)
      when "Int128"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int128), observed_elements)
      when "UInt128"  then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt128), observed_elements)
      when "Int256"   then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, Int256Value), observed_elements)
      when "UInt256"  then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, UInt256Value), observed_elements)
      when "BFloat16" then append_materialized_array_array_nullable_numeric(values, batch.array_array_nullable_numeric_values(column, BFloat16Value), observed_elements)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(Nullable(T))) numeric leaf type")
      end
    end

    private def append_array_array_numeric_values(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
      observed_elements : UInt64,
    ) : UInt64
      case element_type
      when "UInt8"    then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt8), observed_elements)
      when "UInt16"   then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt16), observed_elements)
      when "UInt32"   then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt32), observed_elements)
      when "UInt64"   then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt64), observed_elements)
      when "Int8"     then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int8), observed_elements)
      when "Int16"    then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int16), observed_elements)
      when "Int32"    then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int32), observed_elements)
      when "Int64"    then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int64), observed_elements)
      when "Float32"  then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Float32), observed_elements)
      when "Float64"  then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Float64), observed_elements)
      when "Int128"   then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int128), observed_elements)
      when "UInt128"  then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt128), observed_elements)
      when "Int256"   then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, Int256Value), observed_elements)
      when "UInt256"  then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, UInt256Value), observed_elements)
      when "BFloat16" then append_materialized_array_array_numeric(values, batch.array_array_numeric_values(column, BFloat16Value), observed_elements)
      else
        raise UnsupportedFormatError.new("unsupported Array(Array(T)) numeric leaf type")
      end
    end

    private def array_nullable_numeric_values_for(
      batch : WidePartTableBatch,
      column : String,
      element_type : String,
    ) : WidePartArrayNullableNumericSlice
      case element_type
      when "UInt8"    then batch.array_nullable_numeric_values(column, UInt8)
      when "UInt16"   then batch.array_nullable_numeric_values(column, UInt16)
      when "UInt32"   then batch.array_nullable_numeric_values(column, UInt32)
      when "UInt64"   then batch.array_nullable_numeric_values(column, UInt64)
      when "Int8"     then batch.array_nullable_numeric_values(column, Int8)
      when "Int16"    then batch.array_nullable_numeric_values(column, Int16)
      when "Int32"    then batch.array_nullable_numeric_values(column, Int32)
      when "Int64"    then batch.array_nullable_numeric_values(column, Int64)
      when "Int128"   then batch.array_nullable_numeric_values(column, Int128)
      when "UInt128"  then batch.array_nullable_numeric_values(column, UInt128)
      when "Int256"   then batch.array_nullable_numeric_values(column, Int256Value)
      when "UInt256"  then batch.array_nullable_numeric_values(column, UInt256Value)
      when "BFloat16" then batch.array_nullable_bfloat16s_for(column)
      when "Float32"  then batch.array_nullable_numeric_values(column, Float32)
      when "Float64"  then batch.array_nullable_numeric_values(column, Float64)
      else
        raise UnsupportedFormatError.new("unsupported Array nullable numeric leaf type")
      end
    end

    private def append_materialized_array_nullable_numeric(
      values : Array(OfflineColumnValue),
      selected_values : WidePartArrayNullableNumericSlice,
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each { |row| values << row.dup }
      next_elements
    end

    private def append_materialized_array_nullable_uint64s(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(UInt64?)),
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

    private def append_materialized_array_tuple_uint64_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, String))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_number, value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, String)).new(row.size)
        row.each { |number, value| owned_row << {number, String.new(value.to_slice)} }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_tuple_nullable_uint64_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64?, String))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_number, value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64?, String)).new(row.size)
        row.each { |number, value| owned_row << {number, String.new(value.to_slice)} }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_nullable_strings(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(String?)),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |value|
          next if value.nil?

          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(String?).new(row.size)
        row.each do |value|
          if value.nil?
            owned_row << nil
          else
            owned_row << String.new(value.to_slice)
          end
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_map_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, String))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, String)).new(row.size)
        row.each { |key, value| owned_row << {key, String.new(value.to_slice)} }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_map_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, UInt64))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, UInt64)).new(row.size)
        row.each { |key, value| owned_row << {key, value} }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_map_nullable_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, UInt64?))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, UInt64?)).new(row.size)
        row.each { |key, value| owned_row << {key, value} }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_map_nullable_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, String?))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, value|
          if value
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.not_nil!.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, String?)).new(row.size)
        row.each do |key, value|
          owned_value = value.nil? ? nil : String.new(value.not_nil!.to_slice)
          owned_row << {key, owned_value}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_key_map_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, UInt64))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, _value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, UInt64)).new(row.size)
        row.each { |key, value| owned_row << {String.new(key.to_slice), value} }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_uint64_numeric_map_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      array_elements : Array(UInt64),
    ) : UInt64 forall T
      selected_values = batch.map_uint64_numeric_values_for(column_name, type)
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      array_elements[0] = append_materialized_uint64_key_numeric_values(values, selected_values, array_elements[0])
      next_rows
    end

    private def append_materialized_uint64_nullable_numeric_map_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      array_elements : Array(UInt64),
    ) : UInt64 forall T
      selected_values = batch.map_uint64_nullable_numeric_values_for(column_name, type)
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      array_elements[0] = append_materialized_uint64_key_numeric_values(values, selected_values, array_elements[0])
      next_rows
    end

    private def append_materialized_uint64_key_numeric_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, T))),
      observed_elements : UInt64,
    ) : UInt64 forall T
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, T)).new(row.size)
        row.each { |key, value| owned_row << {key, value} }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_string_numeric_map_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_string_bytes : UInt64,
      max_string_bytes : UInt64,
      array_elements : Array(UInt64),
    ) : {UInt64, UInt64} forall T
      selected_values = batch.map_string_numeric_values_for(column_name, type)
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      array_elements[0], next_string_bytes = append_materialized_string_key_numeric_values(
        values,
        selected_values,
        array_elements[0],
        observed_string_bytes,
        max_string_bytes
      )
      {next_rows, next_string_bytes}
    end

    private def append_materialized_string_nullable_numeric_map_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_string_bytes : UInt64,
      max_string_bytes : UInt64,
      array_elements : Array(UInt64),
    ) : {UInt64, UInt64} forall T
      selected_values = batch.map_string_nullable_numeric_values_for(column_name, type)
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      array_elements[0], next_string_bytes = append_materialized_string_key_numeric_values(
        values, selected_values, array_elements[0], observed_string_bytes, max_string_bytes
      )
      {next_rows, next_string_bytes}
    end

    private def append_materialized_string_key_numeric_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, T))),
      observed_elements : UInt64,
      observed_string_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64} forall T
      next_elements = observed_elements
      next_string_bytes = observed_string_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, _value|
          next_string_bytes = checked_materialized_value_string_bytes(
            next_string_bytes,
            key.bytesize.to_u64,
            max_string_bytes
          )
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, T)).new(row.size)
        row.each { |key, value| owned_row << {String.new(key.to_slice), value} }
        values << owned_row
      end
      {next_elements, next_string_bytes}
    end

    private def append_materialized_string_key_map_array_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, Array(UInt64)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, Array(UInt64))).new(row.size)
        row.each do |key, nested_values|
          owned_row << {String.new(key.to_slice), nested_values.dup}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_map_string_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(Tuple(String, UInt64)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          map.each do |key, _value|
            next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(String, UInt64))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(String, UInt64)).new(map.size)
          map.each { |key, value| owned_map << {String.new(key.to_slice), value} }
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_map_array_leaf_for_shape(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      shape : {String, String},
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64}
      case shape
      when {"UInt64", "UInt64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, UInt64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "UInt8"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, UInt8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "UInt16"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, UInt16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "UInt32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, UInt32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Int8"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Int8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Int16"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Int16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Int32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Int32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Int64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Int64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Float32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Float32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "Float64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, Float64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "UInt8"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, UInt8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "UInt16"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, UInt16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "UInt32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, UInt32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Int8"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Int8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Int16"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Int16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Int32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Int32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Int64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Int64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Float32"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Float32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "Float64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, Float64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"UInt64", "String"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, UInt64, String, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "UInt64"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, UInt64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when {"String", "String"}
        append_materialized_array_map_array_leaf_batch(values, batch, column_name, String, String, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        raise UnsupportedFormatError.new("selected Array(Map) Array leaf is not an admitted W84 String or W85 numeric combination")
      end
    end

    private def append_materialized_array_map_array_leaf_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      key_type : K.class,
      leaf_type : V.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall K, V
      selected_values = batch.array_map_array_leaf_values_for(column_name, key_type, leaf_type)
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      next_elements = observed_elements
      next_bytes = observed_bytes

      # Check the complete mark batch before allocating catalog-owned copies.
      # Each nested Array contributes its element slots, including the Map-entry
      # axis and the third-level Array value axis.
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          map.each do |key, nested_values|
            next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
            {% if K == String %}
              next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
            {% end %}
            {% if V == String %}
              nested_values.each do |value|
                next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
              end
            {% end %}
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(K, Array(V)))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(K, Array(V))).new(map.size)
          map.each do |key, nested_values|
            owned_values = Array(V).new(nested_values.size)
            nested_values.each do |value|
              owned_values << {% if V == String %} String.new(value.to_slice) {% else %} value {% end %}
            end
            owned_map << {
              {% if K == String %} String.new(key.to_slice) {% else %} key {% end %},
              owned_values,
            }
          end
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_rows, next_elements, next_bytes}
    end

    private def append_materialized_array_map_string_leaf_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(Tuple(K, V)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64} forall K, V
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          map.each do |key, value|
            {% if K == String %}
              next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
            {% end %}
            if value
              next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
            end
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(K, V))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(K, V)).new(map.size)
          map.each do |key, value|
            owned_map << {
              {% if K == String %} String.new(key.to_slice) {% else %} key {% end %},
              {% if V == String %}
                String.new(value.to_slice)
              {% else %}
                value.try { |string_value| String.new(string_value.to_slice) }
              {% end %},
            }
          end
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_map_bool_leaf_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Array(Tuple(K, V)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64} forall K, V
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          {% if K == String %}
            map.each do |key, _value|
              next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
            end
          {% end %}
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(K, V))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(K, V)).new(map.size)
          map.each do |key, value|
            owned_map << {
              {% if K == String %} String.new(key.to_slice) {% else %} key {% end %},
              value,
            }
          end
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_array_map_numeric_for_type(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      leaf_type : String,
      string_keys : Bool,
      nullable_values : Bool,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64}
      case leaf_type
      when "UInt8"   then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, UInt8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt16"  then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, UInt16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt32"  then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, UInt32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt64"  then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, UInt64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int8"    then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Int8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int16"   then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Int16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int32"   then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Int32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int64"   then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Int64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float32" then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Float32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float64" then append_materialized_array_map_numeric_for_key(values, batch, column_name, string_keys, nullable_values, Float64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        raise UnsupportedFormatError.new("unsupported exact Array(Map) numeric leaf type")
      end
    end

    private def append_materialized_array_map_numeric_for_key(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      string_keys : Bool,
      nullable_values : Bool,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall T
      if nullable_values
        if string_keys
          append_materialized_array_map_nullable_numeric_batch(values, batch, column_name, String, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
        else
          append_materialized_array_map_nullable_numeric_batch(values, batch, column_name, UInt64, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
        end
      elsif string_keys
        append_materialized_array_map_numeric_batch(values, batch, column_name, String, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        append_materialized_array_map_numeric_batch(values, batch, column_name, UInt64, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      end
    end

    private def append_materialized_array_map_numeric_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      key_type : K.class,
      value_type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall K, T
      selected_values = {% if K == String %}
                          batch.array_map_string_numeric_values_for(column_name, value_type)
                        {% else %}
                          batch.array_map_uint64_numeric_values_for(column_name, value_type)
                        {% end %}
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          {% if K == String %}
            map.each do |key, _value|
              next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
            end
          {% end %}
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(K, T))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(K, T)).new(map.size)
          map.each do |key, value|
            {% if K == String %}
              owned_map << {String.new(key.to_slice), value}
            {% else %}
              owned_map << {key, value}
            {% end %}
          end
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_rows, next_elements, next_bytes}
    end

    private def append_materialized_array_map_nullable_numeric_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      key_type : K.class,
      value_type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall K, T
      selected_values = {% if K == String %}
                          batch.array_map_string_nullable_numeric_values_for(column_name, value_type)
                        {% else %}
                          batch.array_map_uint64_nullable_numeric_values_for(column_name, value_type)
                        {% end %}
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |map|
          next_elements = checked_materialized_value_array_elements(next_elements, map.size.to_u64)
          {% if K == String %}
            map.each do |key, _value|
              next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
            end
          {% end %}
        end
      end

      selected_values.each do |row|
        owned_row = Array(Array(Tuple(K, T?))).new(row.size)
        row.each do |map|
          owned_map = Array(Tuple(K, T?)).new(map.size)
          map.each do |key, value|
            {% if K == String %}
              owned_map << {String.new(key.to_slice), value}
            {% else %}
              owned_map << {key, value}
            {% end %}
          end
          owned_row << owned_map
        end
        values << owned_row
      end
      {next_rows, next_elements, next_bytes}
    end

    private def append_materialized_numeric_map_array_for_type(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      leaf_type : String,
      string_keys : Bool,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64}
      case leaf_type
      when "UInt8"   then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt16"  then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt32"  then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt64"  then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int8"    then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Int8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int16"   then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Int16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int32"   then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Int32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int64"   then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Int64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float32" then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Float32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float64" then append_materialized_numeric_map_array_for_key(values, batch, column_name, string_keys, Float64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        raise UnsupportedFormatError.new("unsupported exact Map Array numeric leaf type")
      end
    end

    private def append_materialized_numeric_map_array_for_key(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      string_keys : Bool,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall T
      if string_keys
        append_materialized_numeric_map_array_batch(values, batch, column_name, String, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        append_materialized_numeric_map_array_batch(values, batch, column_name, UInt64, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      end
    end

    private def append_materialized_numeric_map_array_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      key_type : K.class,
      value_type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall K, T
      selected_values = {% if K == String %}
                          batch.map_string_array_numeric_values_for(column_name, value_type)
                        {% else %}
                          batch.map_uint64_array_numeric_values_for(column_name, value_type)
                        {% end %}
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          {% if K == String %}
            next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          {% end %}
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(K, Array(T))).new(row.size)
        row.each do |key, nested_values|
          {% if K == String %}
            owned_row << {String.new(key.to_slice), nested_values.dup}
          {% else %}
            owned_row << {key, nested_values.dup}
          {% end %}
        end
        values << owned_row
      end
      {next_rows, next_elements, next_bytes}
    end

    private def append_materialized_nullable_numeric_map_array_for_type(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      leaf_type : String,
      string_keys : Bool,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64}
      case leaf_type
      when "UInt8"   then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt16"  then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt32"  then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "UInt64"  then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, UInt64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int8"    then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Int8, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int16"   then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Int16, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int32"   then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Int32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Int64"   then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Int64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float32" then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Float32, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      when "Float64" then append_materialized_nullable_numeric_map_array_for_key(values, batch, column_name, string_keys, Float64, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        raise UnsupportedFormatError.new("unsupported exact nullable Map Array numeric leaf type")
      end
    end

    private def append_materialized_nullable_numeric_map_array_for_key(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      string_keys : Bool,
      type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall T
      if string_keys
        append_materialized_nullable_numeric_map_array_batch(values, batch, column_name, String, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      else
        append_materialized_nullable_numeric_map_array_batch(values, batch, column_name, UInt64, type, observed_rows, expected_rows, observed_elements, observed_bytes, max_string_bytes)
      end
    end

    private def append_materialized_nullable_numeric_map_array_batch(
      values : Array(OfflineColumnValue),
      batch : WidePartTableBatch,
      column_name : String,
      key_type : K.class,
      value_type : T.class,
      observed_rows : UInt64,
      expected_rows : UInt64,
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64, UInt64} forall K, T
      selected_values = {% if K == String %}
                          batch.map_string_array_nullable_numeric_values_for(column_name, value_type)
                        {% else %}
                          batch.map_uint64_array_nullable_numeric_values_for(column_name, value_type)
                        {% end %}
      next_rows = checked_materialized_value_rows(observed_rows, selected_values.size.to_u64, expected_rows)
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          {% if K == String %}
            next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          {% end %}
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(K, Array(T?))).new(row.size)
        row.each do |key, nested_values|
          {% if K == String %}
            owned_row << {String.new(key.to_slice), nested_values.dup}
          {% else %}
            owned_row << {key, nested_values.dup}
          {% end %}
        end
        values << owned_row
      end
      {next_rows, next_elements, next_bytes}
    end

    private def append_materialized_uint64_key_map_array_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, Array(UInt64)))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, Array(UInt64))).new(row.size)
        row.each { |key, nested_values| owned_row << {key, nested_values.dup} }
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_string_key_map_array_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, Array(String)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          nested_values.each do |value|
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, Array(String))).new(row.size)
        row.each do |key, nested_values|
          owned_values = Array(String).new(nested_values.size) { |index| String.new(nested_values[index].to_slice) }
          owned_row << {String.new(key.to_slice), owned_values}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_uint64_key_map_array_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, Array(String)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          nested_values.each do |value|
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, Array(String))).new(row.size)
        row.each do |key, nested_values|
          owned_values = Array(String).new(nested_values.size) { |index| String.new(nested_values[index].to_slice) }
          owned_row << {key, owned_values}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_key_map_array_nullable_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, Array(UInt64?)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, Array(UInt64?))).new(row.size)
        row.each do |key, nested_values|
          owned_row << {String.new(key.to_slice), nested_values.dup}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_key_map_array_nullable_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, Array(String?)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          nested_values.each do |value|
            next unless value
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.not_nil!.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, Array(String?))).new(row.size)
        row.each do |key, nested_values|
          owned_values = Array(String?).new(nested_values.size) do |index|
            value = nested_values[index]
            value.nil? ? nil : String.new(value.not_nil!.to_slice)
          end
          owned_row << {String.new(key.to_slice), owned_values}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_uint64_key_map_array_nullable_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, Array(UInt64?)))),
      observed_elements : UInt64,
    ) : UInt64
      next_elements = observed_elements
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, Array(UInt64?))).new(row.size)
        row.each do |key, nested_values|
          owned_row << {key, nested_values.dup}
        end
        values << owned_row
      end
      next_elements
    end

    private def append_materialized_uint64_key_map_array_nullable_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(UInt64, Array(String?)))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |_key, nested_values|
          next_elements = checked_materialized_value_array_elements(next_elements, nested_values.size.to_u64)
          nested_values.each do |value|
            next unless value
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.not_nil!.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(UInt64, Array(String?))).new(row.size)
        row.each do |key, nested_values|
          owned_values = Array(String?).new(nested_values.size) do |index|
            value = nested_values[index]
            value.nil? ? nil : String.new(value.not_nil!.to_slice)
          end
          owned_row << {key, owned_values}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_key_map_nullable_uint64_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, UInt64?))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, _value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, UInt64?)).new(row.size)
        row.each { |key, value| owned_row << {String.new(key.to_slice), value} }
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_key_map_nullable_string_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, String?))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          if value
            next_bytes = checked_materialized_value_string_bytes(next_bytes, value.not_nil!.bytesize.to_u64, max_string_bytes)
          end
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, String?)).new(row.size)
        row.each do |key, value|
          owned_value = value.nil? ? nil : String.new(value.not_nil!.to_slice)
          owned_row << {String.new(key.to_slice), owned_value}
        end
        values << owned_row
      end
      {next_elements, next_bytes}
    end

    private def append_materialized_string_map_values(
      values : Array(OfflineColumnValue),
      selected_values : Slice(Array(Tuple(String, String))),
      observed_elements : UInt64,
      observed_bytes : UInt64,
      max_string_bytes : UInt64,
    ) : {UInt64, UInt64}
      next_elements = observed_elements
      next_bytes = observed_bytes
      selected_values.each do |row|
        next_elements = checked_materialized_value_array_elements(next_elements, row.size.to_u64)
        row.each do |key, value|
          next_bytes = checked_materialized_value_string_bytes(next_bytes, key.bytesize.to_u64, max_string_bytes)
          next_bytes = checked_materialized_value_string_bytes(next_bytes, value.bytesize.to_u64, max_string_bytes)
        end
      end

      selected_values.each do |row|
        owned_row = Array(Tuple(String, String)).new(row.size)
        row.each { |key, value| owned_row << {String.new(key.to_slice), String.new(value.to_slice)} }
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
end
