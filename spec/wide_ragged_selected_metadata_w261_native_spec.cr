require "./spec_helper"
require "file_utils"
require "../scripts/support/wide_ragged_selected_metadata_w261_fixture"

private def w261_native_hex(value : String) : String
  String.build do |io|
    value.to_slice.each { |byte| io << byte.to_s(16).rjust(2, '0') }
  end
end

private def w261_native_string_signature(value : String) : String
  "string:#{w261_native_hex(value)}"
end

private def w261_native_nullable_string_signature(value : CrystalClick::WideTupleLeafColumn::Value) : String
  case value
  when String
    w261_native_string_signature(value)
  when Nil
    "null"
  else
    raise CrystalClick::CorruptPartError.new("W261 native offline nullable String has an unexpected carrier")
  end
end

private def w261_native_tuple_signature(row : CrystalClick::WideTupleRow) : String
  details = row.tuple("details")
  note = w261_native_nullable_string_signature(details["note"])
  "tuple[id=uint64:#{row.value_as("id", UInt64)},details=tuple[note=#{note},score=uint32:#{details.value_as("score", UInt32)}]]"
end

private def w261_native_array_tuple_signature(row : CrystalClick::WideArrayTupleRow) : String
  entries = [] of String
  row.each { |tuple| entries << w261_native_tuple_signature(tuple) }
  "array[#{entries.join(',')}]"
end

private def w261_native_nullable_float64_signature(value : Float64?) : String
  value ? "float64:#{value}" : "null"
end

private def w261_native_map_tuple_signature(row : CrystalClick::WideMapTupleRow) : String
  entries = [] of String
  row.each do |key_value, value_row|
    key = key_value.as(String)
    meta = value_row.tuple("meta")
    note = w261_native_nullable_string_signature(meta["note"])
    score = w261_native_nullable_float64_signature(value_row["score"].as(Float64?))
    entries << "#{w261_native_hex(key)}:tuple[meta=tuple[note=#{note},id=uint64:#{meta.value_as("id", UInt64)}],score=#{score}]"
  end
  "map[#{entries.join(',')}]"
end

private def w261_native_simple_map_signature(values : Array(Tuple(UInt64, UInt64?))) : String
  entries = values.map do |key, value|
    "uint64:#{key}:#{value ? "uint64:#{value}" : "null"}"
  end
  "map[#{entries.join(',')}]"
end

private def w261_native_lookup_map_signature(values : Array(Tuple(String, Array(UInt64?)))) : String
  entries = values.map do |key, children|
    rendered = children.map { |value| value ? "uint64:#{value}" : "null" }
    "#{w261_native_hex(key)}:[#{rendered.join(',')}]"
  end
  "map[#{entries.join(',')}]"
end

private def w261_native_tuple_string_signature(row : CrystalClick::WideTupleRow) : String
  "tuple[n=uint64:#{row.value_as("n", UInt64)},s=#{w261_native_string_signature(row.value_as("s", String))}]"
end

private def w261_native_variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
  case value
  when String
    "variant<String>(#{w261_native_string_signature(value)})"
  when UInt64
    "variant<UInt64>(uint64:#{value})"
  else
    "variant<NULL>(null)"
  end
end

private def w261_native_offline_signature(column : String, value : CrystalClick::OfflineColumnValue) : String
  case column
  when "u"
    "uint64:#{value.as(UInt64)}"
  when "side", "lc"
    w261_native_string_signature(value.as(String))
  when "seq"
    w261_native_array_tuple_signature(value.as(CrystalClick::WideArrayTupleRow))
  when "mapped"
    w261_native_map_tuple_signature(value.as(CrystalClick::WideMapTupleRow))
  when "simple"
    w261_native_simple_map_signature(value.as(Array(Tuple(UInt64, UInt64?))))
  when "lookup"
    w261_native_lookup_map_signature(value.as(Array(Tuple(String, Array(UInt64?)))))
  when "tup"
    w261_native_tuple_string_signature(value.as(CrystalClick::WideTupleRow))
  when "v"
    w261_native_variant_signature(value.as(CrystalClick::VariantStringUInt64Value))
  else
    raise CrystalClick::UnsupportedFormatError.new("W261 native offline signature has no carrier for #{column}")
  end
end

if stock_part = ENV["CRYSTAL_CLICK_W261_STOCK_PART"]?
  describe "W261 native stock Wide OfflineTable values" do
    it "reopens copied real stock bytes and checks exact values, types, ordering, and budgets" do
      parent = File.tempname("crystal-click-w261-native-offline-")
      Dir.mkdir(parent)
      begin
        catalog_fixture = WideRaggedSelectedMetadataW261Fixture.prepare_offline_catalog(
          stock_part,
          File.join(parent, "offline-work"),
        )
        catalog = CrystalClick::OfflineCatalog.open(catalog_fixture[:root])
        table = catalog.table("lab", "events")
        table.columns.map { |column| {column.name, column.type} }.should eq(WideRaggedSelectedMetadataW261Fixture::SCHEMA)

        candidates = table.resolved_scan_parts
        candidates.size.should eq(1)
        File.realpath(candidates[0].path).should eq(File.realpath(catalog_fixture[:part]))

        expected = WideRaggedSelectedMetadataW261Fixture.expected_signatures
        actual = Hash(String, Array(String)).new
        WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
          budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS[column]
          values = table[column].values(
            max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
            max_string_bytes: budget[:string_bytes],
            max_tuple_cells: budget[:tuple_cells],
          )
          values.size.to_u64.should eq(WideRaggedSelectedMetadataW261Fixture::ROW_COUNT)
          actual[column] = values.map { |value| w261_native_offline_signature(column, value) }

          if budget[:string_bytes] > 0_u64
            error = expect_raises(CrystalClick::BoundsError) do
              table[column].values(
                max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
                max_string_bytes: budget[:string_bytes] - 1_u64,
                max_tuple_cells: budget[:tuple_cells],
              )
            end
            error.message.to_s.should contain("String payload limit")
          end

          if budget[:tuple_cells] > 0_u64
            error = expect_raises(CrystalClick::BoundsError) do
              table[column].values(
                max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
                max_string_bytes: budget[:string_bytes],
                max_tuple_cells: budget[:tuple_cells] - 1_u64,
              )
            end
            error.message.to_s.should contain("Tuple cell limit")
          end
        end
        actual.should eq(expected)

        row_error = expect_raises(CrystalClick::BoundsError) do
          table["u"].values(
            max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT - 1_u64,
            max_string_bytes: 0_u64,
            max_tuple_cells: 0_u64,
          )
        end
        row_error.message.to_s.should contain("row limit")
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
