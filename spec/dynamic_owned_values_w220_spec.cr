require "./spec_helper"
require "file_utils"

private alias W220DynamicFixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  granules: Array(Array(CrystalClick::BinaryValue)),
)

private alias W220NestedFamilyTypes = NamedTuple(
  string: CrystalClick::BinaryDataType,
  uint64: CrystalClick::BinaryDataType,
  nullable_string: CrystalClick::BinaryDataType,
  low_cardinality: CrystalClick::BinaryDataType,
  variant: CrystalClick::BinaryDataType,
  dynamic: CrystalClick::BinaryDataType,
  nested: CrystalClick::BinaryDataType,
)

private def w220_write_catalog_shell(
  declaration : String,
  table_columns : String? = nil,
  with_materialized_view : Bool = false,
  &
)
  root = File.tempname("crystal-click-w220-owned-dynamic-values-")
  Dir.mkdir(root)

  begin
    metadata_path = File.join(root, "metadata")
    FileUtils.mkdir_p(metadata_path)
    FileUtils.mkdir_p(File.join(root, "store"))

    database_uuid = "22000000-0000-4000-8000-000000000001"
    table_uuid = "22000000-0000-4000-8000-000000000002"
    view_uuid = "22000000-0000-4000-8000-000000000003"
    File.write(
      File.join(metadata_path, "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
    )

    database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_path)
    declared_columns = table_columns || "    `pk` UInt64,\n    `payload` #{declaration}"
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{declared_columns}\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )

    if with_materialized_view
      File.write(
        File.join(database_path, "view.sql"),
        "ATTACH MATERIALIZED VIEW _ UUID '#{view_uuid}' TO lab.events\n(\n    `payload` #{declaration}\n)\nAS SELECT payload FROM lab.events\n"
      )
    end

    table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    yield root, table_path
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w220_nested_family_types : W220NestedFamilyTypes
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  nullable_string = CrystalClick::BinaryDataType.nullable(string)
  low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
  variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  nested = CrystalClick::BinaryDataType.nested(
    [low_cardinality, variant, dynamic] of CrystalClick::BinaryDataType,
    ["label", "choice", "payload"] of String,
  )
  {
    string:          string,
    uint64:          uint64,
    nullable_string: nullable_string,
    low_cardinality: low_cardinality,
    variant:         variant,
    dynamic:         dynamic,
    nested:          nested,
  }
end

private def w220_nested_family_record(
  types : W220NestedFamilyTypes,
  label : String?,
  variant_index : Int32?,
  variant_child : CrystalClick::BinaryValue?,
  payload : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  choice = if index = variant_index
             CrystalClick::BinaryValue.variant(types[:variant], index, variant_child.not_nil!)
           else
             CrystalClick::BinaryValue.variant_null(types[:variant])
           end
  nullable = if label
               CrystalClick::BinaryValue.nullable(types[:nullable_string], CrystalClick::BinaryValue.string(label))
             else
               CrystalClick::BinaryValue.nullable(types[:nullable_string])
             end
  label_value = CrystalClick::BinaryValue.low_cardinality(types[:low_cardinality], nullable)
  CrystalClick::BinaryValue.tuple(
    types[:nested].child_at(0),
    [
      label_value,
      choice,
      CrystalClick::BinaryValue.dynamic(types[:dynamic], payload),
    ] of CrystalClick::BinaryValue,
  )
end

private def w220_nested_family_granules(types : W220NestedFamilyTypes) : Array(Array(CrystalClick::BinaryValue))
  string_arm = types[:variant].children.index(types[:string]).not_nil!
  uint64_arm = types[:variant].children.index(types[:uint64]).not_nil!
  empty_first = CrystalClick::BinaryValue.nested(types[:nested], [] of CrystalClick::BinaryValue)
  ragged = CrystalClick::BinaryValue.nested(types[:nested], [
    w220_nested_family_record(types, "red", string_arm, CrystalClick::BinaryValue.string("arm-red"), CrystalClick::BinaryValue.uint64(7_u64)),
    w220_nested_family_record(types, nil, uint64_arm, CrystalClick::BinaryValue.uint64(42_u64), CrystalClick::BinaryValue.string("shared")),
    w220_nested_family_record(types, "red", nil, nil, CrystalClick::BinaryValue.uint64(9_u64)),
  ] of CrystalClick::BinaryValue)
  empty_later = CrystalClick::BinaryValue.nested(types[:nested], [] of CrystalClick::BinaryValue)
  final = CrystalClick::BinaryValue.nested(types[:nested], [
    w220_nested_family_record(types, "blue", string_arm, CrystalClick::BinaryValue.string("arm-blue"), CrystalClick::BinaryValue.string("final-shared")),
    w220_nested_family_record(types, "red", uint64_arm, CrystalClick::BinaryValue.uint64(8_u64), CrystalClick::BinaryValue.uint64(10_u64)),
  ] of CrystalClick::BinaryValue)
  [
    [empty_first] of CrystalClick::BinaryValue,
    [ragged] of CrystalClick::BinaryValue,
    [empty_later] of CrystalClick::BinaryValue,
    [final] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w220_dynamic_fixture(case_id : String) : W220DynamicFixture
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  wrap = ->(child : CrystalClick::BinaryValue?) { CrystalClick::BinaryValue.dynamic(dynamic, child) }
  number = ->(value : Int32) { wrap.call(CrystalClick::BinaryValue.uint64(value.to_u64)) }
  text = ->(value : String) { wrap.call(CrystalClick::BinaryValue.string(value)) }
  null = -> { wrap.call(nil) }

  case case_id
  when "root_dynamic"
    granules = [
      [null.call, number.call(7)] of CrystalClick::BinaryValue,
      [text.call("spill-a"), number.call(8)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: dynamic, structures: {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "array_dynamic"
    array = CrystalClick::BinaryDataType.array(dynamic)
    row = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array, items) }
    granules = [
      [row.call([number.call(7), text.call("array-a")] of CrystalClick::BinaryValue), row.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [row.call([null.call] of CrystalClick::BinaryValue), row.call([number.call(8), text.call("array-b")] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: array, structures: {"root.elements" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "tuple_dynamic"
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, string] of CrystalClick::BinaryDataType,
      ["d", "text"] of String,
    )
    row = ->(value : CrystalClick::BinaryValue, label : String) {
      CrystalClick::BinaryValue.tuple(
        tuple,
        [value, CrystalClick::BinaryValue.string(label)] of CrystalClick::BinaryValue,
      )
    }
    granules = [
      [row.call(null.call, "null"), row.call(number.call(7), "number")] of CrystalClick::BinaryValue,
      [row.call(text.call("tuple-a"), "spill"), row.call(number.call(8), "tail")] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: tuple, structures: {"root.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "nested_dynamic"
    nested = CrystalClick::BinaryDataType.nested(
      [dynamic, string] of CrystalClick::BinaryDataType,
      ["d", "text"] of String,
    )
    tuple = nested.child_at(0)
    row = ->(value : CrystalClick::BinaryValue, label : String) {
      CrystalClick::BinaryValue.tuple(
        tuple,
        [value, CrystalClick::BinaryValue.string(label)] of CrystalClick::BinaryValue,
      )
    }
    granules = [
      [
        CrystalClick::BinaryValue.nested(nested, [row.call(null.call, "null")] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.nested(nested, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [
        CrystalClick::BinaryValue.nested(nested, [row.call(number.call(7), "number")] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.nested(nested, [row.call(text.call("nested-a"), "spill")] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: nested, structures: {"root.elements.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "dynamic_tuple_dynamic"
    inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple = CrystalClick::BinaryDataType.tuple([inner_dynamic] of CrystalClick::BinaryDataType)
    nested = ->(child : CrystalClick::BinaryValue?) {
      inner = CrystalClick::BinaryValue.dynamic(inner_dynamic, child)
      actual = CrystalClick::BinaryValue.tuple(tuple, [inner] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValue.dynamic(dynamic, actual)
    }
    granules = [
      [nested.call(CrystalClick::BinaryValue.uint64(7_u64)), nested.call(nil)] of CrystalClick::BinaryValue,
      [nested.call(CrystalClick::BinaryValue.string("inner-a")), nested.call(CrystalClick::BinaryValue.uint64(8_u64))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {
      type:       dynamic,
      structures: {
        "root"               => CrystalClick::DynamicStructure.new([tuple] of CrystalClick::BinaryDataType),
        "root.arm.1.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
      },
      granules: granules,
    }
  else
    raise ArgumentError.new("unknown W220 Dynamic carrier")
  end
end

private def w220_write_dynamic_part(
  table_path : String,
  part_name : String,
  fixture : W220DynamicFixture,
  keys : Array(UInt64),
  profile : CrystalClick::BinaryBulkProfile,
  rows_per_mark : Int32 = 2,
) : Nil
  unless keys.size == fixture[:granules].sum(&.size)
    raise ArgumentError.new("W220 key count differs from fixture rows")
  end
  part = File.join(table_path, part_name)
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    fixture[:type],
    fixture[:structures],
    fixture[:granules],
    rows_per_mark: rows_per_mark,
    profile: profile,
  ).should eq(part)
end

private def w220_expect_binary_values!(actual : Array(CrystalClick::OfflineColumnValue), expected : Array(CrystalClick::BinaryValue)) : Nil
  actual.size.should eq(expected.size)
  expected.each_with_index do |value, index|
    owned = actual[index].as(CrystalClick::BinaryValue)
    owned.type.name.should eq(value.type.name)
    CrystalClick::BinaryValueCodec.encode(owned).should eq(CrystalClick::BinaryValueCodec.encode(value))
  end
end

private def w220_string_dynamic_fixture(
  values : Array(String),
  roster : CrystalClick::BinaryDataType,
) : W220DynamicFixture
  raise ArgumentError.new("W220 string fixture needs four rows") unless values.size == 4
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  wrap = ->(value : String) {
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string(value))
  }
  granules = [
    [wrap.call(values[0]), wrap.call(values[1])] of CrystalClick::BinaryValue,
    [wrap.call(values[2]), wrap.call(values[3])] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
  {
    type:       dynamic,
    structures: {"root" => CrystalClick::DynamicStructure.new([roster] of CrystalClick::BinaryDataType)},
    granules:   granules,
  }
end

private def w220_recursive_cells_fixture(leaf : CrystalClick::BinaryDataType, prefix : String) : W220DynamicFixture
  outer_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  tuple = CrystalClick::BinaryDataType.tuple([inner_dynamic] of CrystalClick::BinaryDataType)
  rows = Array(CrystalClick::BinaryValue).new(4) do |index|
    actual = if leaf.name == "UInt64"
               CrystalClick::BinaryValue.uint64((index + 1).to_u64)
             else
               CrystalClick::BinaryValue.string("#{prefix}-#{index}")
             end
    inner = CrystalClick::BinaryValue.dynamic(inner_dynamic, actual)
    wrapped = CrystalClick::BinaryValue.tuple(tuple, [inner] of CrystalClick::BinaryValue)
    CrystalClick::BinaryValue.dynamic(outer_dynamic, wrapped)
  end
  granules = [rows[0, 2], rows[2, 2]]
  {
    type:       outer_dynamic,
    structures: {
      "root"               => CrystalClick::DynamicStructure.new([tuple] of CrystalClick::BinaryDataType),
      "root.arm.1.field.0" => CrystalClick::DynamicStructure.new([leaf] of CrystalClick::BinaryDataType),
    },
    granules: granules,
  }
end

private def w220_json_type : CrystalClick::BinaryDataType
  id = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"id" => id} of String => CrystalClick::BinaryDataType,
  )
end

private def w220_json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  id_type = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"id", CrystalClick::BinaryValue.fixed(id_type, Bytes[id])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w220_json_object_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w220_budget_counters(budget : CrystalClick::ObjectValuesMaterializationBudget)
  {
    budget.retained_logical_bytes,
    budget.string_payload_bytes,
    budget.tuple_cells,
    budget.node_count,
    budget.element_count,
  }
end

private def w220_grid_workspace_lower_bound(reader : CrystalClick::DynamicBulkColumnReader) : UInt64
  mark_count = reader.mark_count.to_u64
  per_grid = instance_sizeof(CrystalClick::CompressedMarkGrid).to_u64 +
             instance_sizeof(Array(Int64)).to_u64 +
             instance_sizeof(Array(UInt64)).to_u64 +
             (mark_count + 1_u64) * sizeof(Int64).to_u64 +
             mark_count * sizeof(UInt64).to_u64
  reader.physical_stream_names.size.to_u64 * per_grid
end

private def w220_encoded_marks(reader : CrystalClick::DynamicBulkColumnReader) : Array(Array(Bytes))
  reader.read_marks(0, reader.mark_count).map do |mark|
    mark.map { |value| CrystalClick::BinaryValueCodec.encode(value) }
  end
end

describe "W220 owned offline values for Dynamic-bearing columns" do
  it "retains all five generic carriers with both Dynamic String profiles" do
    ["root_dynamic", "array_dynamic", "tuple_dynamic", "nested_dynamic", "dynamic_tuple_dynamic"].each do |case_id|
      fixture = w220_dynamic_fixture(case_id)
      expected = [] of CrystalClick::BinaryValue
      fixture[:granules].each { |mark| expected.concat(mark) }

      [
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.with_size_stream,
      ].each do |profile|
        w220_write_catalog_shell(fixture[:type].name) do |root, table_path|
          w220_write_dynamic_part(table_path, "all_1_1_0", fixture, [1_u64, 2_u64, 3_u64, 4_u64], profile)
          selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
          w220_expect_binary_values!(selection.values, expected)
        end
      end
    end
  end

  it "rejects a later part with a different exact Dynamic-bearing declaration" do
    first = w220_dynamic_fixture("root_dynamic")
    later = w220_dynamic_fixture("array_dynamic")
    w220_write_catalog_shell(first[:type].name) do |root, table_path|
      w220_write_dynamic_part(table_path, "all_1_1_0", first, [1_u64, 2_u64, 3_u64, 4_u64], CrystalClick::BinaryBulkProfile.single_stream)
      w220_write_dynamic_part(table_path, "all_2_2_0", later, [5_u64, 6_u64, 7_u64, 8_u64], CrystalClick::BinaryBulkProfile.with_size_stream)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]

      returned_any_result = false
      expect_raises(CrystalClick::CorruptPartError) do
        selection.values
        returned_any_result = true
      end
      returned_any_result.should be_false
    end
  end

  it "accumulates row, String, and recursive-cell limits across marks and immutable parts" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    first = w220_string_dynamic_fixture(["a", "b", "c", "d"], uint64)
    second = w220_string_dynamic_fixture(["e", "f", "g", "h"], string)

    w220_write_catalog_shell(first[:type].name) do |root, table_path|
      w220_write_dynamic_part(table_path, "all_1_1_0", first, [1_u64, 2_u64, 3_u64, 4_u64], CrystalClick::BinaryBulkProfile.single_stream)
      w220_write_dynamic_part(table_path, "all_2_2_0", second, [5_u64, 6_u64, 7_u64, 8_u64], CrystalClick::BinaryBulkProfile.with_size_stream)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]

      row_error = expect_raises(CrystalClick::BoundsError) { selection.values(max_rows: 7_u64) }
      row_error.message.should eq("selected column materialization exceeds row limit")
      expect_raises(CrystalClick::BoundsError) { selection.values(max_string_bytes: 7_u64) }
      owned = selection.values(max_rows: 8_u64, max_string_bytes: 8_u64)
      owned.size.should eq(8)
      owned.map { |value| value.as(CrystalClick::BinaryValue).element_at(0).as_string }.should eq(["a", "b", "c", "d", "e", "f", "g", "h"])
    end

    integer_cells = w220_recursive_cells_fixture(uint64, "unused")
    string_cells = w220_recursive_cells_fixture(string, "cell")
    w220_write_catalog_shell(integer_cells[:type].name) do |root, table_path|
      w220_write_dynamic_part(table_path, "all_1_1_0", integer_cells, [1_u64, 2_u64, 3_u64, 4_u64], CrystalClick::BinaryBulkProfile.single_stream)
      w220_write_dynamic_part(table_path, "all_2_2_0", string_cells, [5_u64, 6_u64, 7_u64, 8_u64], CrystalClick::BinaryBulkProfile.with_size_stream)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      expect_raises(CrystalClick::BoundsError) { selection.values(max_tuple_cells: 23_u64) }
      selection.values(max_tuple_cells: 24_u64).size.should eq(8)
    end
  end

  it "keeps the exact legacy Dynamic empty route and rejects malformed Dynamic-bearing declarations" do
    w220_write_catalog_shell("Dynamic") do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      selection.values.should be_empty
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    w220_write_catalog_shell(dynamic.name) do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      selection.values.should be_empty

      rows_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_rows: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_ROWS + 1_u64)
      end
      rows_error.message.should eq("selected column row limit exceeds hard limit")
      strings_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_string_bytes: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES + 1_u64)
      end
      strings_error.message.should eq("selected column String payload limit exceeds hard limit")
      cells_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_tuple_cells: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS + 1_u64)
      end
      cells_error.message.should eq("selected column Tuple cell limit exceeds hard limit")
    end

    w220_write_catalog_shell("Array(Dynamic)") do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      selection.values.should be_empty
    end

    w220_write_catalog_shell("Array( Dynamic )") do |root, _table_path|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.find { |column| column.name == "payload" }.not_nil!.type.should eq("Array( Dynamic )")
      table.metadata_ddl.not_nil!.should contain("`payload` Array( Dynamic )")

      source_candidate, selected_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve("Array( Dynamic )")
      source_candidate.should be_true
      selected_type.not_nil!.name.should eq("Array(Dynamic)")
      CrystalClick::DynamicBulkColumnDeclaration.parse(selected_type.not_nil!.name).should_not be_nil

      table["payload"].values.should be_empty
    end

    [
      "Array(Dynamic(max_types=1), UInt64)",
      "Tuple(v Variant(UInt64, String), d Dynamic(max_types = 1))",
      "Array(Dynamic(max_types = 32))",
    ].each do |declaration|
      w220_write_catalog_shell(declaration) do |root, _table_path|
        selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
        error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
        error.message.should eq("selected table column type is unsupported")
      end
    end

    # Nothing is valid in the binary value/type grammar but is not an admitted
    # offline selected-column materialization type.
    w220_write_catalog_shell("Nothing") do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      error.message.should eq("selected table column type is unsupported")
    end
  end

  it "preserves ALIAS, materialized-view, and hard-limit rejection precedence" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    w220_write_catalog_shell(
      dynamic.name,
      table_columns: "    `pk` UInt64,\n    `source` Dynamic,\n    `payload` Dynamic ALIAS source"
    ) do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      hard_limit_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_rows: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_ROWS + 1_u64)
      end
      hard_limit_error.message.should eq("selected column row limit exceeds hard limit")
      alias_error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      alias_error.message.should eq("ALIAS columns cannot be materialized")
    end

    w220_write_catalog_shell(dynamic.name, with_materialized_view: true) do |root, _table_path|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["view"]["payload"]
      hard_limit_error = expect_raises(CrystalClick::BoundsError) do
        selection.values(max_tuple_cells: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS + 1_u64)
      end
      hard_limit_error.message.should eq("selected column Tuple cell limit exceeds hard limit")
      view_error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      view_error.message.should eq("materialized view is metadata-only; direct part inventory and row scans are unsupported")
    end
  end

  it "retains the W203 LC and Variant sibling profile including empty Nested rows" do
    types = w220_nested_family_types
    nested = types[:nested]
    uint64 = types[:uint64]
    structures = {
      "root.elements.field.2" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    }
    granules = w220_nested_family_granules(types)
    expected = [] of CrystalClick::BinaryValue
    granules.each { |mark| expected.concat(mark) }

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      w220_write_catalog_shell(nested.name) do |root, table_path|
        fixture = {type: nested, structures: structures, granules: granules}
        w220_write_dynamic_part(
          table_path,
          "all_1_1_0",
          fixture,
          [3_u64, 8_u64, 13_u64, 21_u64],
          profile,
          rows_per_mark: 1,
        )
        selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
        values = selection.values
        w220_expect_binary_values!(values, expected)
        first = values[1].as(CrystalClick::BinaryValue)
        first.element_count.should eq(3)
        first.element_at(0).child_at(0).child_at(0).child_at(0).as_string.should eq("red")
        first.element_at(0).child_at(1).variant_child?.not_nil!.as_string.should eq("arm-red")
        first.element_at(0).child_at(2).child_at(0).as_uint64.should eq(7_u64)
        values[0].as(CrystalClick::BinaryValue).element_count.should eq(0)
        values[2].as(CrystalClick::BinaryValue).element_count.should eq(0)
      end
    end
  end

  it "retains ordinary and Shared inline JSON actuals as detached nominal BinaryValue roots" do
    json = w220_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    plans = [
      {"root", structure.canonical_index_for(json), w220_json_object_plan(json)},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    ordinary_rows = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w220_json_value(json, 41_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w220_json_value(json, 42_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    ordinary_fixture = {type: dynamic, structures: {"root" => structure}, granules: ordinary_rows}
    w220_write_catalog_shell(dynamic.name) do |root, table_path|
      part = File.join(table_path, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        ordinary_fixture[:type],
        ordinary_fixture[:structures],
        ordinary_fixture[:granules],
        rows_per_mark: 1,
        json_object_plans: plans,
      ).should eq(part)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      values = selection.values.map(&.as(CrystalClick::BinaryValue))
      values.map { |value| value.child_at(0).json_row.value_for("id").not_nil!.byte_at(0) }.should eq([41_u8, 42_u8])
    end

    inline_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    inline_structures = {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    inline_rows = [
      [CrystalClick::BinaryValue.dynamic(inline_dynamic, w220_json_value(json, 51_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(inline_dynamic, w220_json_value(json, 52_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    w220_write_catalog_shell(inline_dynamic.name) do |root, table_path|
      part = File.join(table_path, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        inline_dynamic,
        inline_structures,
        inline_rows,
        rows_per_mark: 1,
      ).should eq(part)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      values = selection.values.map(&.as(CrystalClick::BinaryValue))
      values.map { |value| value.child_at(0).json_row.value_for("id").not_nil!.byte_at(0) }.should eq([51_u8, 52_u8])
    end
  end

  it "owns returned Dynamic roots after materialization and exposes detached children and bytes" do
    fixture = w220_string_dynamic_fixture(["keep", "this", "value", "safe"], CrystalClick::BinaryDataType.primitive("UInt64"))
    retained = w220_write_catalog_shell(fixture[:type].name) do |root, table_path|
      w220_write_dynamic_part(table_path, "all_1_1_0", fixture, [1_u64, 2_u64, 3_u64, 4_u64], CrystalClick::BinaryBulkProfile.with_size_stream)
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      values = selection.values
      first = values.first.as(CrystalClick::BinaryValue)
      values.clear
      first
    end
    first = retained.as(CrystalClick::BinaryValue)
    first.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
    first.element_count.should eq(1)
    detached_elements = first.elements
    detached_elements.clear
    first.element_count.should eq(1)
    payload = first.element_at(0).bytes
    payload[0] = 'X'.ord.to_u8
    first.element_at(0).as_string.should eq("keep")
  end

  it "charges a nominal BinaryDataType once and rejects over-budget charges atomically" do
    descriptor = CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))] of CrystalClick::BinaryDataType,
      ["items"] of String,
    )

    admitted = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: UInt64::MAX)
    admitted.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    before_admitted = w220_budget_counters(admitted)
    admitted.charge_binary_type(descriptor)
    admitted.retained_logical_bytes.should be > before_admitted[0]
    admitted.node_count.should be > before_admitted[3]
    admitted.element_count.should be > before_admitted[4]

    probe = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: UInt64::MAX)
    probe.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    probe.charge_binary_type(descriptor)
    complete_logical_bytes = probe.retained_logical_bytes

    depth_limited = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: UInt64::MAX,
      max_depth: 2,
    )
    depth_limited.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    before = w220_budget_counters(depth_limited)
    expect_raises(CrystalClick::BoundsError) { depth_limited.charge_binary_type(descriptor) }
    w220_budget_counters(depth_limited).should eq(before)

    node_limited = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: UInt64::MAX,
      max_nodes: 1_u64,
    )
    node_limited.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    before = w220_budget_counters(node_limited)
    expect_raises(CrystalClick::BoundsError) { node_limited.charge_binary_type(descriptor) }
    w220_budget_counters(node_limited).should eq(before)

    logical_limited = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: complete_logical_bytes - 1_u64,
    )
    logical_limited.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    before = w220_budget_counters(logical_limited)
    expect_raises(CrystalClick::BoundsError) { logical_limited.charge_binary_type(descriptor) }
    w220_budget_counters(logical_limited).should eq(before)

    workspace_limited = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: complete_logical_bytes,
    )
    workspace_limited.reserve_base(0_u64, 0_u64, descriptor_nodes: 0_u64)
    before = w220_budget_counters(workspace_limited)
    expect_raises(CrystalClick::BoundsError) { workspace_limited.charge_binary_type(descriptor, 1_u64) }
    w220_budget_counters(workspace_limited).should eq(before)
  end

  it "charges retained per-stream mark grids and detaches their reader snapshots" do
    ["root_dynamic", "nested_dynamic"].each do |case_id|
      fixture = w220_dynamic_fixture(case_id)
      finer_granules = [] of Array(CrystalClick::BinaryValue)
      fixture[:granules].each do |granule|
        granule.each { |value| finer_granules << [value] of CrystalClick::BinaryValue }
      end
      finer_fixture = {
        type:       fixture[:type],
        structures: fixture[:structures],
        granules:   finer_granules,
      }

      [
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.with_size_stream,
      ].each do |profile|
        w220_write_catalog_shell(fixture[:type].name) do |_root, table_path|
          w220_write_dynamic_part(
            table_path,
            "all_1_1_0",
            fixture,
            [1_u64, 2_u64, 3_u64, 4_u64],
            profile,
            rows_per_mark: 2,
          )
          w220_write_dynamic_part(
            table_path,
            "all_2_2_0",
            finer_fixture,
            [1_u64, 2_u64, 3_u64, 4_u64],
            profile,
            rows_per_mark: 1,
          )

          small = CrystalClick::DynamicBulkColumnReader.open(
            File.join(table_path, "all_1_1_0"), "payload", fixture[:type]
          )
          large = CrystalClick::DynamicBulkColumnReader.open(
            File.join(table_path, "all_2_2_0"), "payload", fixture[:type]
          )
          small.mark_count.should eq(2)
          large.mark_count.should eq(4)
          small_names = small.physical_stream_names
          large_names = large.physical_stream_names
          small_names.should_not be_empty
          small_names.sort.should eq(large_names.sort)

          small_workspace = small.retained_grid_workspace_bytes
          large_workspace = large.retained_grid_workspace_bytes
          small_workspace.should be > w220_grid_workspace_lower_bound(small)
          large_workspace.should be > w220_grid_workspace_lower_bound(large)
          extra_slots_per_stream =
            (large.mark_count - small.mark_count).to_u64 *
              (sizeof(Int64) + sizeof(UInt64)).to_u64
          minimum_increment = small_names.size.to_u64 * extra_slots_per_stream
          large_workspace.should be >= (small_workspace + minimum_increment)

          expected_marks = w220_encoded_marks(small)
          schema = small.schema_declaration
          source = small.source_declaration
          small_names.clear
          small.mark_row_counts.clear
          small.selected_checksum_names.clear
          grid = CrystalClick::CompressedMarkGrid.new(
            [0_i64, 2_i64, 4_i64], [2_u64, 2_u64], 0, 4_i64
          )
          detached_positions = grid.positions
          detached_rows = grid.rows_per_mark
          detached_positions.clear
          detached_rows.clear
          grid.position_at(1).should eq(2_i64)
          grid.row_count_at(0).should eq(2_u64)
          small.retained_grid_workspace_bytes.should eq(small_workspace)
          small.physical_stream_names.sort.should eq(large.physical_stream_names.sort)
          small.schema_declaration.should eq(schema)
          small.source_declaration.should eq(source)
          w220_encoded_marks(small).should eq(expected_marks)
        end
      end
    end
  end
end
