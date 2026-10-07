require "./spec_helper"
require "file_utils"

private alias W211DynamicFixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  granules: Array(Array(CrystalClick::BinaryValue)),
)

private def w211_u64(value : Int) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.uint64(value.to_u64)
end

private def w211_dynamic_fixture(case_id : String) : W211DynamicFixture
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_value = ->(child : CrystalClick::BinaryValue?) { CrystalClick::BinaryValue.dynamic(dynamic, child) }
  u = ->(value : Int32) { dynamic_value.call(w211_u64(value)) }
  s = ->(value : String) { dynamic_value.call(CrystalClick::BinaryValue.string(value)) }
  n = -> { dynamic_value.call(nil) }

  case case_id
  when "root_dynamic"
    granules = [
      [n.call, n.call] of CrystalClick::BinaryValue,
      [u.call(7), s.call("root-spill-a")] of CrystalClick::BinaryValue,
      [u.call(0), s.call("root-spill-b")] of CrystalClick::BinaryValue,
      [u.call(99), s.call("root-spill-c")] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: dynamic, structures: {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "array_dynamic"
    array = CrystalClick::BinaryDataType.array(dynamic)
    array_value = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array, items) }
    granules = [
      [array_value.call([] of CrystalClick::BinaryValue), array_value.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [array_value.call([u.call(7), s.call("array-spill-a")] of CrystalClick::BinaryValue),
       array_value.call([n.call] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [array_value.call([u.call(0), u.call(42), s.call("array-spill-b")] of CrystalClick::BinaryValue),
       array_value.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [array_value.call([s.call("array-spill-c")] of CrystalClick::BinaryValue),
       array_value.call([u.call(99), n.call] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: array, structures: {"root.elements" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "tuple_dynamic"
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, string] of CrystalClick::BinaryDataType,
      ["d", "text"] of String,
    )
    pair = ->(value : CrystalClick::BinaryValue, text : String) {
      CrystalClick::BinaryValue.tuple(tuple, [value, CrystalClick::BinaryValue.string(text)] of CrystalClick::BinaryValue)
    }
    granules = [
      [pair.call(n.call, "first-null"), pair.call(n.call, "second-null")] of CrystalClick::BinaryValue,
      [pair.call(u.call(7), "ordinary"), pair.call(s.call("tuple-spill-a"), "shared")] of CrystalClick::BinaryValue,
      [pair.call(u.call(0), "zero"), pair.call(n.call, "null-again")] of CrystalClick::BinaryValue,
      [pair.call(s.call("tuple-spill-b"), "novel"), pair.call(u.call(99), "last")] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: tuple, structures: {"root.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "nested_dynamic"
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    nested = CrystalClick::BinaryDataType.nested(
      [low_cardinality, variant, dynamic, string] of CrystalClick::BinaryDataType,
      ["label", "choice", "d", "text"] of String,
    )
    string_arm = variant.children.index(string).not_nil!
    uint64_arm = variant.children.index(uint64).not_nil!
    choice_string = ->(value : String) { CrystalClick::BinaryValue.variant(variant, string_arm, CrystalClick::BinaryValue.string(value)) }
    choice_uint64 = ->(value : Int32) { CrystalClick::BinaryValue.variant(variant, uint64_arm, w211_u64(value)) }
    choice_null = -> { CrystalClick::BinaryValue.variant_null(variant) }
    record = ->(label : String?, choice : CrystalClick::BinaryValue, payload : CrystalClick::BinaryValue, text_value : String) {
      tuple_type = nested.child_at(0)
      low = tuple_type.child_at(0)
      nullable = low.child_at(0)
      label_value = if value = label
                      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(value))
                    else
                      CrystalClick::BinaryValue.nullable(nullable)
                    end
      CrystalClick::BinaryValue.tuple(
        tuple_type,
        [
          CrystalClick::BinaryValue.low_cardinality(low, label_value),
          choice,
          payload,
          CrystalClick::BinaryValue.string(text_value),
        ] of CrystalClick::BinaryValue,
      )
    }
    empty = -> { CrystalClick::BinaryValue.nested(nested, [] of CrystalClick::BinaryValue) }
    row = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.nested(nested, items) }
    granules = [
      [empty.call, empty.call] of CrystalClick::BinaryValue,
      [
        row.call([
          record.call(nil, choice_string.call("after-empty"), u.call(7), "a"),
          record.call("x", choice_uint64.call(701), s.call("nested-spill-a"), "num-first"),
          record.call("x", choice_null.call, u.call(9), "third"),
        ] of CrystalClick::BinaryValue),
        row.call([record.call("x", choice_string.call("repeat"), u.call(11), "repeat")] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [
        empty.call,
        row.call([
          record.call("", choice_uint64.call(0), u.call(0), "default-label"),
          record.call(nil, choice_uint64.call(42), s.call("nested-spill-b"), "null-label"),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [
        row.call([record.call("novel", choice_string.call("last"), s.call("nested-spill-c"), "final")] of CrystalClick::BinaryValue),
        row.call([
          record.call("x", choice_uint64.call(999), u.call(99), "final-num"),
          record.call("x", choice_null.call, n.call, "tail"),
          record.call("novel", choice_string.call("repeat"), u.call(10), "repeat"),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: nested, structures: {"root.elements.field.2" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}, granules: granules}
  when "dynamic_tuple_dynamic"
    inner_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple = CrystalClick::BinaryDataType.tuple([inner_dynamic] of CrystalClick::BinaryDataType)
    outer_tuple = ->(child : CrystalClick::BinaryValue?) {
      nested_value = CrystalClick::BinaryValue.dynamic(inner_dynamic, child)
      actual = CrystalClick::BinaryValue.tuple(tuple, [nested_value] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValue.dynamic(dynamic, actual)
    }
    outer_string = ->(value : String) { dynamic_value.call(CrystalClick::BinaryValue.string(value)) }
    granules = [
      [dynamic_value.call(nil), dynamic_value.call(nil)] of CrystalClick::BinaryValue,
      [outer_tuple.call(w211_u64(7)), outer_tuple.call(CrystalClick::BinaryValue.string("inner-spill-a"))] of CrystalClick::BinaryValue,
      [outer_string.call("outer-spill"), outer_tuple.call(nil)] of CrystalClick::BinaryValue,
      [outer_tuple.call(w211_u64(99)), outer_tuple.call(CrystalClick::BinaryValue.string("inner-spill-b"))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    {type: dynamic, structures: {
      "root"               => CrystalClick::DynamicStructure.new([tuple] of CrystalClick::BinaryDataType),
      "root.arm.1.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    }, granules: granules}
  else
    raise ArgumentError.new("W211 carrier is outside the copied W203 fixture roster")
  end
end

private def w211_same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
  left.type == right.type && CrystalClick::BinaryValueCodec.encode(left) == CrystalClick::BinaryValueCodec.encode(right)
end

private def w211_expect_marks!(actual : Array(Array(CrystalClick::BinaryValue)), expected : Array(Array(CrystalClick::BinaryValue))) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |rows, mark|
    rows.size.should eq(expected[mark].size)
    rows.each_with_index { |value, row| w211_same_value?(value, expected[mark][row]).should be_true }
  end
end

private def w211_write_fixture(part : String, fixture : W211DynamicFixture, profile : CrystalClick::BinaryBulkProfile) : Nil
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    part, "pk", Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
    "payload", fixture[:type], fixture[:structures], fixture[:granules],
    rows_per_mark: 2, profile: profile,
  ).should eq(part)
end

private def w211_profiles : Array(CrystalClick::BinaryBulkProfile)
  [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream]
end

private alias W211JSONFixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  granules: Array(Array(CrystalClick::BinaryValue)),
  plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
  json_used: CrystalClick::BinaryDataType,
  json_unused: CrystalClick::BinaryDataType,
)

private def w211_json_type(max_dynamic_types : Int) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: max_dynamic_types,
    typed_paths: {
      "id"    => uint8,
      "maybe" => CrystalClick::BinaryDataType.nullable(uint8),
    } of String => CrystalClick::BinaryDataType,
  )
end

private def w211_json_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["counter"] of String),
    {"counter" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w211_json_value(
  type : CrystalClick::BinaryDataType,
  id : UInt8,
  counter : UInt64,
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"counter", CrystalClick::BinaryValue.uint64(counter)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w211_json_fixture : W211JSONFixture
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic = CrystalClick::BinaryDataType.dynamic(3)
  used = w211_json_type(1)
  unused = w211_json_type(2)
  structure = CrystalClick::DynamicStructure.new([used, unused, uint8] of CrystalClick::BinaryDataType)
  plans = [
    {"root", structure.canonical_index_for(used), w211_json_plan(used)},
    {"root", structure.canonical_index_for(unused), w211_json_plan(unused)},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  wrap = ->(actual : CrystalClick::BinaryValue) { CrystalClick::BinaryValue.dynamic(dynamic, actual) }
  granules = [
    [wrap.call(CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])), wrap.call(CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8]))] of CrystalClick::BinaryValue,
    [wrap.call(CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])), wrap.call(CrystalClick::BinaryValue.fixed(uint8, Bytes[20_u8]))] of CrystalClick::BinaryValue,
    [wrap.call(w211_json_value(used, 41_u8, 401_u64)), wrap.call(w211_json_value(used, 42_u8, 402_u64))] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
  {
    type:        dynamic,
    structures:  {"root" => structure},
    granules:    granules,
    plans:       plans,
    json_used:   used,
    json_unused: unused,
  }
end

private def w211_write_json_fixture(
  part : String,
  fixture : W211JSONFixture,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    part,
    "pk",
    Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
    "payload",
    fixture[:type],
    fixture[:structures],
    fixture[:granules],
    rows_per_mark: 2,
    profile: profile,
    json_object_plans: fixture[:plans],
  ).should eq(part)
end

private def w211_corrupt_unused_json_child!(part : String, fixture : W211JSONFixture) : Nil
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
    fixture[:type],
    fixture[:structures],
    CrystalClick::BinaryCodecBudget.new(limits, true),
    json_object_plans: fixture[:plans],
  )
  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload", limits)
  structure = fixture[:structures]["root"]
  unused_index = structure.canonical_index_for(fixture[:json_unused])
  site = physical.json_object_site("root", unused_index)
  child_name = site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
  child_path = File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
  bytes = File.read(child_path).to_slice.dup
  raise "W211 unused Object child file is unexpectedly empty" if bytes.empty?
  bytes[0] = bytes[0] ^ 0xff_u8
  File.write(child_path, bytes)
end

private def w211_write_single_dynamic_part(part : String, actual_type : CrystalClick::BinaryDataType, actual : CrystalClick::BinaryValue) : Nil
  dynamic = CrystalClick::BinaryDataType.dynamic(1)
  structures = {"root" => CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)}
  rows = [[CrystalClick::BinaryValue.dynamic(dynamic, actual)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    part,
    "pk",
    Slice[1_u64],
    "payload",
    dynamic,
    structures,
    rows,
    rows_per_mark: 1,
  ).should eq(part)
end

class CrystalClick::DynamicBulkColumnDeclaration
  # Parser-only seam keeps the root-Nested inherited wire-byte boundary
  # separate from canonical SQL-name temporary accounting.
  def self.w211_test_parse_root_nested(
    source : String,
    limits : BinaryCodecLimits,
  ) : BinaryDataType?
    parse_root_nested(source.to_slice, 1, limits)
  end
end

class CrystalClick::WidePartTable
  # Test-only access to the private per-mark Dynamic owner adapter.
  def self.w211_test_dynamic_preflight(
    reader : DynamicBulkColumnReader,
    mark_index : Int32,
    expected_rows : UInt64,
    remaining_bytes : UInt64,
  ) : UInt64
    DynamicBulkColumnAdapter.preflight_owner(reader, mark_index, expected_rows, remaining_bytes)
  end

  def self.w211_test_dynamic_materialize(
    reader : DynamicBulkColumnReader,
    expected_type : BinaryDataType,
    mark_index : Int32,
    expected_rows : UInt64,
    remaining_bytes : UInt64,
  ) : {Array(BinaryValue), UInt64}
    DynamicBulkColumnAdapter.materialize_mark(
      reader, expected_type, mark_index, expected_rows, remaining_bytes
    )
  end
end

describe "W211 generic Dynamic table batches" do
  it "reuses one recursive leaf reader for all W203 carriers, both String profiles, candidates and windows" do
    ["root_dynamic", "array_dynamic", "tuple_dynamic", "nested_dynamic", "dynamic_tuple_dynamic"].each do |case_id|
      w211_profiles.each do |profile|
        parent = File.tempname("crystal-click-w211-dynamic-carrier-")
        Dir.mkdir(parent)
        begin
          part = File.join(parent, "all_1_1_0")
          fixture = w211_dynamic_fixture(case_id)
          w211_write_fixture(part, fixture, profile)
          table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

          observed = Array(Array(CrystalClick::BinaryValue)).new(fixture[:granules].size) do
            [] of CrystalClick::BinaryValue
          end
          table.scan_typed do |batch|
            batch.part_index.should eq(0)
            batch.mark_row_offset.should eq(0_u64)
            batch.part_row_offset.should eq((batch.mark_index * 2).to_u64)
            batch.source_row_offset.should eq((batch.mark_index * 2).to_u64)
            batch.values_for("pk", UInt64).size.should eq(fixture[:granules][batch.mark_index].size)
            observed[batch.mark_index] = batch.dynamic_bulk_values_for("payload").to_a
          end
          w211_expect_marks!(observed, fixture[:granules])

          candidate = [] of CrystalClick::BinaryValue
          candidate_marks = [] of Int32
          table.scan_typed_candidate_marks([[1_i32, 3_i32]]) do |batch|
            candidate_marks << batch.mark_index
            batch.mark_row_offset.should eq(0_u64)
            batch.part_row_offset.should eq((batch.mark_index * 2).to_u64)
            batch.source_row_offset.should eq((batch.mark_index * 2).to_u64)
            candidate.concat(batch.dynamic_bulk_values_for("payload").to_a)
          end
          candidate_marks.should eq([1, 3])
          w211_same_value?(candidate[0], fixture[:granules][1][0]).should be_true
          w211_same_value?(candidate[1], fixture[:granules][1][1]).should be_true
          w211_same_value?(candidate[2], fixture[:granules][3][0]).should be_true
          w211_same_value?(candidate[3], fixture[:granules][3][1]).should be_true

          window = [] of CrystalClick::BinaryValue
          window_offsets = [] of Tuple(Int32, UInt64, UInt64, UInt64)
          table.scan_typed_window(1_u64, 3) do |batch|
            window_offsets << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset, batch.source_row_offset}
            window.concat(batch.dynamic_bulk_values_for("payload").to_a)
          end
          window_offsets.should eq([{0, 1_u64, 1_u64, 1_u64}, {1, 0_u64, 2_u64, 2_u64}])
          expected_window = fixture[:granules].flatten[1, 3]
          window.size.should eq(expected_window.size)
          window.each_with_index { |value, index| w211_same_value?(value, expected_window[index]).should be_true }

          final_window = [] of CrystalClick::BinaryValue
          table.scan_typed_window(7_u64, 1) do |batch|
            batch.mark_index.should eq(3)
            batch.mark_row_offset.should eq(1_u64)
            batch.part_row_offset.should eq(7_u64)
            batch.source_row_offset.should eq(7_u64)
            final_window.concat(batch.dynamic_bulk_values_for("payload").to_a)
          end
          final_window.size.should eq(1)
          w211_same_value?(final_window[0], fixture[:granules][3][1]).should be_true

          eof_callbacks = 0
          table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
          eof_callbacks.should eq(0)

          numeric_callbacks = 0
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_numeric { |_batch| numeric_callbacks += 1 }
          end
          numeric_callbacks.should eq(0)

          scalar_callbacks = 0
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan { |_batch| scalar_callbacks += 1 }
          end
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_candidate_marks([[0]]) { |_batch| scalar_callbacks += 1 }
          end
          scalar_callbacks.should eq(0)

          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_typed do |batch|
              batch.dynamic_bulk_values_for("pk")
            end
          end
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_typed do |batch|
              batch.dynamic_bulk_values_for("missing")
            end
          end
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_typed do |batch|
              batch.recursive_values_for("payload")
            end
          end
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end
end

describe CrystalClick::DynamicBulkColumnDeclaration do
  it "adapts only canonical root Nested through one implicit named Tuple" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array = CrystalClick::BinaryDataType.array(dynamic)
    source = "Nested(a Dynamic(max_types=1), b Array(Dynamic(max_types=1)))"
    nested = CrystalClick::DynamicBulkColumnDeclaration.parse(source).not_nil!

    nested.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    nested.contains_dynamic?.should be_true
    nested.contains_json?.should be_false
    nested.name.should eq(source)
    tuple = nested.child_at(0)
    tuple.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)
    tuple.field_names.should eq(["a", "b"])
    tuple.children.should eq([dynamic, array])

    named_tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, array] of CrystalClick::BinaryDataType,
      ["a", "b"] of String,
    )
    explicit_nested = CrystalClick::BinaryDataType.nested(named_tuple)
    explicit_nested.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    explicit_nested.child_at(0).same?(named_tuple).should be_true
    explicit_nested.name.should eq(source)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested(CrystalClick::BinaryDataType.primitive("UInt8"))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested(CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested(CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType, [] of String))
    end

    CrystalClick::DynamicBulkColumnDeclaration.parse("Nested()").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Nested(Dynamic(max_types=1))").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Nested(a Dynamic(max_types=1),b Array(Dynamic(max_types=1)))").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Array(Nested(a Dynamic(max_types=1)))").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse(dynamic.name).should eq(dynamic)
    CrystalClick::DynamicBulkColumnDeclaration.parse(w211_json_fixture[:json_used].name).should be_nil
  end

  it "honors exact inherited depth, node, element and rendered-byte boundaries for root Nested" do
    source = "Nested(a Dynamic(max_types=1))"
    descriptor_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: 1_000_000,
    )
    parsed = CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: descriptor_limits).not_nil!
    parsed.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    parsed.name.should eq(source)

    [
      CrystalClick::BinaryCodecLimits.new(2, 4, 3, 1_000_000_u64),
      CrystalClick::BinaryCodecLimits.new(3, 3, 3, 1_000_000_u64),
      CrystalClick::BinaryCodecLimits.new(3, 4, 2, 1_000_000_u64),
    ].each do |too_small|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: too_small)
      end
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicBulkColumnDeclaration.parse(source, root_depth: 2, limits: descriptor_limits)
    end

    # At the declaration parser boundary, the adapted Tuple is one byte
    # shorter than Nested, but its inherited accounting must charge that
    # spelling delta in addition to Object's byte_size + 1 allowance and the
    # two retained copies of the field name.
    parser_exact = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: (source.bytesize.to_u64 + 3_u64).to_i,
    )
    CrystalClick::DynamicBulkColumnDeclaration.w211_test_parse_root_nested(source, parser_exact).should_not be_nil
    parser_one_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: (source.bytesize.to_u64 + 2_u64).to_i,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicBulkColumnDeclaration.w211_test_parse_root_nested(source, parser_one_short)
    end

    # Public parse also builds the canonical SQL name under its own stronger
    # temporary bound. Derive that independent threshold instead of letting
    # it masquerade as the smaller inherited declaration-accounting limit.
    name_bounds = CrystalClick::BinaryTypeNameBudget.measure(
      parsed,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    name_bounds.should eq({33_u64, 175_u64})
    render_exact = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: name_bounds[1].to_i,
    )
    CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: render_exact).should_not be_nil
    expect_raises(CrystalClick::UnsupportedFormatError) do
      render_one_short = CrystalClick::BinaryCodecLimits.new(
        max_depth: 3,
        max_nodes: 4,
        max_elements: 3,
        max_bytes: (name_bounds[1] - 1_u64).to_i,
      )
      CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: render_one_short)
    end

    oversized_source = "Nested(" + (0...64).map { |index| "field#{index} Dynamic(max_types=1)" }.join(", ") + ")"
    tiny_source_limit = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 512,
      max_elements: 512,
      max_bytes: 32,
    )
    CrystalClick::DynamicBulkColumnDeclaration.w211_test_parse_root_nested(
      oversized_source, tiny_source_limit
    ).should be_nil
  end
end

describe "W211 Dynamic table mark ownership adapter" do
  it "charges the decoded owner before return and rejects wrong type or row expectations" do
    parent = File.tempname("crystal-click-w211-dynamic-owner-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      fixture = w211_dynamic_fixture("root_dynamic")
      w211_write_fixture(part, fixture, CrystalClick::BinaryBulkProfile.single_stream)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
      mark_index = 1_i32
      expected_rows = fixture[:granules][mark_index].size.to_u64

      preflight = CrystalClick::WidePartTable.w211_test_dynamic_preflight(
        reader, mark_index, expected_rows, UInt64::MAX
      )
      preflight.should be > 0_u64
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w211_test_dynamic_preflight(
          reader, mark_index, expected_rows, preflight - 1_u64
        )
      end

      values, retained = CrystalClick::WidePartTable.w211_test_dynamic_materialize(
        reader, fixture[:type], mark_index, expected_rows, UInt64::MAX
      )
      retained.should be >= preflight
      w211_expect_marks!([values], [fixture[:granules][mark_index]])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w211_test_dynamic_materialize(
          reader, fixture[:type], mark_index, expected_rows, retained - 1_u64
        )
      end

      wrong_type = CrystalClick::BinaryDataType.dynamic(max_types: 2)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w211_test_dynamic_materialize(
          reader, wrong_type, mark_index, expected_rows, UInt64::MAX
        )
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w211_test_dynamic_materialize(
          reader, fixture[:type], mark_index, expected_rows + 1_u64, UInt64::MAX
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "W211 Dynamic(JSON) table schedule validation" do
  it "reads direct JSON actuals and preflights corrupted unused JSON children before empty and EOF scans" do
    fixture = w211_json_fixture
    w211_profiles.each do |profile|
      parent = File.tempname("crystal-click-w211-dynamic-json-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        w211_write_json_fixture(part, fixture, profile)
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        observed = Array(Array(CrystalClick::BinaryValue)).new(fixture[:granules].size) do
          [] of CrystalClick::BinaryValue
        end
        table.scan_typed do |batch|
          batch.part_index.should eq(0)
          batch.part_row_offset.should eq((batch.mark_index * 2).to_u64)
          observed[batch.mark_index] = batch.dynamic_bulk_values_for("payload").to_a
        end
        w211_expect_marks!(observed, fixture[:granules])

        empty_part = File.join(parent, "all_2_2_0")
        w211_write_json_fixture(empty_part, fixture, profile)
        empty_table = CrystalClick::WidePartTable.open_selected_typed([empty_part], ["pk", "payload"])
        w211_corrupt_unused_json_child!(empty_part, fixture)
        empty_callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          empty_table.scan_typed_candidate_marks([[] of Int32]) do |_batch|
            empty_callbacks += 1
          end
        end
        empty_callbacks.should eq(0)

        eof_part = File.join(parent, "all_3_3_0")
        w211_write_json_fixture(eof_part, fixture, profile)
        eof_table = CrystalClick::WidePartTable.open_selected_typed([eof_part], ["pk", "payload"])
        w211_corrupt_unused_json_child!(eof_part, fixture)
        eof_callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          eof_table.scan_typed_window(eof_table.total_row_count, 1) do |_batch|
            eof_callbacks += 1
          end
        end
        eof_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end

describe "W211 Dynamic LowCardinality complete-schedule replay" do
  it "rejects a corrupted nested dictionary even when the candidate schedule is empty" do
    fixture = w211_dynamic_fixture("nested_dynamic")
    parent = File.tempname("crystal-click-w211-dynamic-lc-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w211_write_fixture(part, fixture, CrystalClick::BinaryBulkProfile.single_stream)

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      plan = CrystalClick::BinaryDynamicBulkPlan.new(
        fixture[:type], fixture[:structures], CrystalClick::BinaryBulkProfile.single_stream, limits
      )
      site = plan.low_cardinality_sites.first? || raise("W211 Nested fixture has no LowCardinality owner")
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload", limits)
      physical_name = physical.stream_names[site.dictionary_role]
      dictionary_path = File.join(part, "#{CrystalClick::StreamName.hash(physical_name)}.bin")
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      bytes = File.read(dictionary_path).to_slice.dup
      raise "W211 LowCardinality dictionary file is unexpectedly empty" if bytes.empty?
      bytes[0] = bytes[0] ^ 0xff_u8
      File.write(dictionary_path, bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "W211 exact Dynamic and nominal JSON accessor boundaries" do
  it "preserves the legacy exact bare-Dynamic accessor without routing it through the generic batch" do
    parent = File.tempname("crystal-click-w211-legacy-dynamic-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64],
        "payload",
        Slice["legacy-a", "legacy-b", "legacy-c"],
        rows_per_mark: 2,
      ).should eq(part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed = [] of String
      table.scan_typed do |batch|
        observed.concat(batch.dynamic_strings_for("payload").to_a)
      end
      observed.should eq(["legacy-a", "legacy-b", "legacy-c"])

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.dynamic_bulk_values_for("payload")
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not expose nominal JSON columns through the Dynamic-bulk accessor" do
    parent = File.tempname("crystal-click-w211-nominal-json-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        [{7_u64, "seven"}, {8_u64, "eight"}] of Tuple(UInt64, String),
        rows_per_mark: 1,
      ).should eq(part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.dynamic_bulk_values_for("payload")
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "W211 Dynamic projection guard" do
  it "rejects a Dynamic-bearing projection child before callbacks" do
    root = File.tempname("crystal-click-w211-dynamic-projection-")
    Dir.mkdir(root)
    begin
      parent = File.join(root, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_pair(
        parent,
        "pk",
        Slice[1_u64],
        "base",
        Slice[2_u64],
        rows_per_mark: 1,
      ).should eq(parent)

      fixture = w211_dynamic_fixture("root_dynamic")
      projection = File.join(parent, "by_dynamic.proj")
      w211_write_fixture(projection, fixture, CrystalClick::BinaryBulkProfile.single_stream)

      callbacks = 0
      expect_raises(
        CrystalClick::UnsupportedFormatError,
        "Dynamic bulk columns are unsupported in typed projections",
      ) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent], "by_dynamic", ["pk", "payload"]
        )
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "W211 per-part Dynamic actual rosters" do
  it "allows different actual alternatives across immutable parts but rejects declared schema drift before callbacks" do
    parent = File.tempname("crystal-click-w211-part-rosters-")
    Dir.mkdir(parent)
    begin
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      string = CrystalClick::BinaryDataType.primitive("String")
      first_part = File.join(parent, "all_1_1_0")
      second_part = File.join(parent, "all_2_2_0")
      w211_write_single_dynamic_part(first_part, uint64, w211_u64(7))
      w211_write_single_dynamic_part(second_part, string, CrystalClick::BinaryValue.string("second-part-string"))

      table = CrystalClick::WidePartTable.open_selected_typed([first_part, second_part], ["pk", "payload"])
      observed = [] of Tuple(Int32, UInt64, UInt64, UInt8)
      table.scan_typed do |batch|
        value = batch.dynamic_bulk_values_for("payload")[0]
        value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
        actual = value.child_at(0)
        observed << {batch.part_index, batch.part_row_offset, batch.source_row_offset, actual.type.tag}
      end
      observed.should eq([
        {0, 0_u64, 0_u64, CrystalClick::BinaryDataType::TAG_UINT64},
        {1, 0_u64, 1_u64, CrystalClick::BinaryDataType::TAG_STRING},
      ])

      drift_part = File.join(parent, "all_3_3_0")
      changed_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
      structures = {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
      rows = [[CrystalClick::BinaryValue.dynamic(changed_dynamic, w211_u64(9))] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        drift_part,
        "pk",
        Slice[3_u64],
        "payload",
        changed_dynamic,
        structures,
        rows,
        rows_per_mark: 1,
      ).should eq(drift_part)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        drifted = CrystalClick::WidePartTable.open_selected_typed([first_part, drift_part], ["pk", "payload"])
        drifted.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::ObjectValuesMaterializationBudget do
  it "charges all BinaryValue descendants atomically and preserves every counter on rejection" do
    value = CrystalClick::BinaryValue.string("transactional dynamic owner")
    values = [value] of CrystalClick::BinaryValue
    complete = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: UInt64::MAX)
    complete.reserve_binary_values_base(1_u64)
    complete.charge_binary_values(values)
    complete_bytes = complete.retained_logical_bytes
    complete_bytes.should be > 0_u64

    too_small = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: complete_bytes - 1_u64)
    too_small.reserve_binary_values_base(1_u64)
    before = {
      too_small.retained_logical_bytes,
      too_small.string_payload_bytes,
      too_small.tuple_cells,
      too_small.node_count,
      too_small.element_count,
    }
    expect_raises(CrystalClick::BoundsError) { too_small.charge_binary_values(values) }
    {
      too_small.retained_logical_bytes,
      too_small.string_payload_bytes,
      too_small.tuple_cells,
      too_small.node_count,
      too_small.element_count,
    }.should eq(before)
  end
end
