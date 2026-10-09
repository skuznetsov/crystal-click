require "file_utils"
require "./spec_helper"

private def w234p_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 3_u64)
end

private def w234p_qbit_data_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.qbit(w234p_qbit_type)
end

private def w234p_qbit_value(seed : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(
    CrystalClick::QBitValue.new(
      w234p_qbit_type,
      Bytes[seed, (seed + 1_u8).to_u8, (seed + 2_u8).to_u8],
    ),
  )
end

private def w234p_document(path : String, value : CrystalClick::BinaryValue) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({path => value} of String => CrystalClick::BinaryValue)
end

private def w234p_assert_inferred_qbit_marks(
  marks : Array(Array(CrystalClick::ObjectDocument)),
  expected_present : Array(Bool),
  expected_types : Array(CrystalClick::BinaryDataType?),
  expected_raws : Array(Array(Bytes)),
  expected_offset : Int32 = 0,
) : Nil
  index = expected_offset
  marks.each do |mark|
    mark.each do |document|
      if expected_present[index]
        document.has_path?("payload").should be_true
        value = document.value_for("payload")
        value.type.should eq(expected_types[index].not_nil!)
        raws = expected_raws[index]
        case value.type.tag
        when CrystalClick::BinaryDataType::TAG_QBIT
          raws.size.should eq(1)
          value.qbit_value.raw_bytes.should eq(raws[0])
        when CrystalClick::BinaryDataType::TAG_ARRAY
          value.element_count.should eq(raws.size)
          value.element_count.times do |element_index|
            leaf = value.element_at(element_index)
            leaf.type.should eq(value.type.child_at(0))
            leaf.qbit_value.raw_bytes.should eq(raws[element_index])
          end
        else
          raise "unexpected W234 inferred QBit actual type: #{value.type.name}"
        end
      else
        document.has_path?("payload").should be_false
      end
      index += 1
    end
  end
end

describe "W234 Object runtime QBit complete parts" do
  it "reads inferred root QBit and Array(QBit) rosters across sparse unequal marks" do
    qbit = w234p_qbit_data_type
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    dynamic_roster = CrystalClick::DynamicStructure.new(
      [qbit, array_qbit] of CrystalClick::BinaryDataType,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload"] of String),
      {"payload" => dynamic_roster} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)

    root_first = w234p_qbit_value(0x11_u8)
    array_first = CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue)
    array_two = CrystalClick::BinaryValue.array(
      array_qbit,
      [w234p_qbit_value(0x21_u8), w234p_qbit_value(0x31_u8)] of CrystalClick::BinaryValue,
    )
    array_one = CrystalClick::BinaryValue.array(
      array_qbit,
      [w234p_qbit_value(0x41_u8)] of CrystalClick::BinaryValue,
    )
    root_last = w234p_qbit_value(0x51_u8)
    missing = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
    granules = [
      [
        w234p_document("payload", root_first),
        missing,
      ] of CrystalClick::ObjectDocument,
      [
        w234p_document("payload", array_first),
        w234p_document("payload", array_two),
      ] of CrystalClick::ObjectDocument,
      [
        w234p_document("payload", array_one),
        w234p_document("payload", root_last),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
    expected_present = [true, false, true, true, true, true] of Bool
    expected_types = [qbit, nil, array_qbit, array_qbit, array_qbit, qbit] of CrystalClick::BinaryDataType?
    expected_raws = [
      [Bytes[0x11_u8, 0x12, 0x13]] of Bytes,
      [] of Bytes,
      [] of Bytes,
      [Bytes[0x21_u8, 0x22, 0x23], Bytes[0x31_u8, 0x32, 0x33]] of Bytes,
      [Bytes[0x41_u8, 0x42, 0x43]] of Bytes,
      [Bytes[0x51_u8, 0x52, 0x53]] of Bytes,
    ] of Array(Bytes)

    parent = File.tempname("crystal-click-w234-object-inferred-qbit-sparse-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[101_u64, 102_u64, 103_u64, 104_u64, 105_u64, 106_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 2,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.row_count.should eq(6_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])

      full = reader.read_marks(0, 3)
      full.size.should eq(3)
      w234p_assert_inferred_qbit_marks(full, expected_present, expected_types, expected_raws)

      selected = reader.read_marks(1, 1)
      selected.size.should eq(1)
      w234p_assert_inferred_qbit_marks(
        selected,
        expected_present,
        expected_types,
        expected_raws,
        2,
      )
      reader.read_marks(3, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "persists every non-Variant typed Dynamic QBit product through the public part API" do
    qbit = w234p_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    tuple_qbit = CrystalClick::BinaryDataType.tuple([qbit, uint8] of CrystalClick::BinaryDataType)
    map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
    nested_qbit = CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["q"] of String)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType),
    )
    array_nullable_tuple = CrystalClick::BinaryDataType.array(nullable_tuple)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 8)
    actual_types = [qbit, array_qbit, tuple_qbit, map_qbit, nested_qbit, array_nullable_tuple] of CrystalClick::BinaryDataType

    qbit_a = w234p_qbit_value(0x11_u8)
    qbit_b = w234p_qbit_value(0x21_u8)
    qbit_c = w234p_qbit_value(0x31_u8)
    qbit_d = w234p_qbit_value(0x41_u8)
    qbit_e = w234p_qbit_value(0x51_u8)
    qbit_f = w234p_qbit_value(0x61_u8)
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_qbit,
      [qbit_b, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])] of CrystalClick::BinaryValue,
    )
    map_value = CrystalClick::BinaryValue.map(
      map_qbit,
      [CrystalClick::BinaryValue.string("key"), qbit_d] of CrystalClick::BinaryValue,
    )
    nested_tuple = CrystalClick::BinaryValue.tuple(
      CrystalClick::BinaryNestedType.tuple_for(nested_qbit),
      [qbit_e] of CrystalClick::BinaryValue,
    )
    nested_value = CrystalClick::BinaryValue.nested(
      nested_qbit,
      [nested_tuple] of CrystalClick::BinaryValue,
    )
    nullable_present = CrystalClick::BinaryValue.nullable(
      nullable_tuple,
      CrystalClick::BinaryValue.tuple(
        nullable_tuple.child_at(0),
        [qbit_f] of CrystalClick::BinaryValue,
      ),
    )
    nullable_null = CrystalClick::BinaryValue.nullable(nullable_tuple)
    nullable_array = CrystalClick::BinaryValue.array(
      array_nullable_tuple,
      [nullable_present, nullable_null] of CrystalClick::BinaryValue,
    )

    dynamic_values = [
      CrystalClick::BinaryValue.dynamic(dynamic, qbit_a),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(array_qbit, [qbit_b] of CrystalClick::BinaryValue),
      ),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic, tuple_value),
      CrystalClick::BinaryValue.dynamic(dynamic, map_value),
      CrystalClick::BinaryValue.dynamic(dynamic, nested_value),
      CrystalClick::BinaryValue.dynamic(dynamic, nullable_array),
      CrystalClick::BinaryValue.dynamic(dynamic),
    ] of CrystalClick::BinaryValue
    expected = dynamic_values.map { |value| CrystalClick::BinaryValueCodec.encode(value) }
    granules = [
      [
        w234p_document("payload", dynamic_values[0]),
        w234p_document("payload", dynamic_values[1]),
        w234p_document("payload", dynamic_values[2]),
        w234p_document("payload", dynamic_values[3]),
      ] of CrystalClick::ObjectDocument,
      [
        w234p_document("payload", dynamic_values[4]),
        w234p_document("payload", dynamic_values[5]),
        w234p_document("payload", dynamic_values[6]),
        w234p_document("payload", dynamic_values[7]),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    schema = CrystalClick::ObjectDocumentSchema.new({"payload" => dynamic})
    object_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      object_structures,
      schema.typed_paths,
      {"payload" => CrystalClick::DynamicStructure.new(actual_types)},
    )

    parent = File.tempname("crystal-click-w234-object-qbit-typed-dynamic-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 4,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.row_count.should eq(8_u64)
      reader.mark_row_counts.should eq([4_u64, 4_u64])
      full = reader.read_marks(0, 2)
      full.size.should eq(2)
      full.each_with_index do |mark, mark_index|
        mark.size.should eq(4)
        mark.each_with_index do |document, row_index|
          offset = mark_index * 4 + row_index
          value = document.value_for("payload")
          value.type.should eq(dynamic)
          CrystalClick::BinaryValueCodec.encode(value).should eq(expected[offset])
        end
      end
      selected = reader.read_marks(1, 1)
      selected.size.should eq(1)
      selected[0].map { |document| CrystalClick::BinaryValueCodec.encode(document.value_for("payload")) }.should eq(
        expected[4, 4],
      )
      reader.read_marks(2, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "shares the typed Dynamic QBit shape-element limit across sibling paths per mark" do
    qbit = w234p_qbit_data_type
    inner_array = CrystalClick::BinaryDataType.array(qbit)
    actual = CrystalClick::BinaryDataType.array(inner_array)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 8)
    typed_paths = {"left" => dynamic, "right" => dynamic} of String => CrystalClick::BinaryDataType
    writer_schema = CrystalClick::ObjectDocumentSchema.new(typed_paths)
    roster = CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      writer_schema.typed_paths,
      {
        "left"  => roster,
        "right" => roster,
      } of String => CrystalClick::DynamicStructure,
    )

    empty_inner = CrystalClick::BinaryValue.array(inner_array, [] of CrystalClick::BinaryValue)
    outer = CrystalClick::BinaryValue.array(
      actual,
      Array(CrystalClick::BinaryValue).new(256) { empty_inner },
    )
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, outer)
    document = CrystalClick::ObjectDocument.new(
      {
        "left"  => dynamic_value,
        "right" => dynamic_value,
      } of String => CrystalClick::BinaryValue,
    )
    granules = [
      [document] of CrystalClick::ObjectDocument,
      [document] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    parent = File.tempname("crystal-click-w234-object-typed-qbit-sibling-budget-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[11_u64, 22_u64],
        "payload",
        writer_schema,
        plan,
        granules,
        rows_per_mark: 1,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      exact_schema = CrystalClick::ObjectDocumentSchema.new(
        typed_paths,
        limits: CrystalClick::BinaryCodecLimits.new(64, 4096, 516, 1_000_000),
      )
      exact_reader = CrystalClick::ObjectColumnReader.open(part, "payload", exact_schema)
      exact_reader.row_count.should eq(2_u64)
      exact_reader.mark_row_counts.should eq([1_u64, 1_u64])

      short_schema = CrystalClick::ObjectDocumentSchema.new(
        typed_paths,
        limits: CrystalClick::BinaryCodecLimits.new(64, 4096, 515, 1_000_000),
      )
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectColumnReader.open(part, "payload", short_schema)
      end
      error.message.not_nil!.should eq("binary codec element limit exceeded")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "persists recursive QBit values in advanced Object Shared Copy without widening borrowed values" do
    qbit = w234p_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    tuple_qbit = CrystalClick::BinaryDataType.tuple([qbit, uint8] of CrystalClick::BinaryDataType)
    map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
    nested_qbit = CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["q"] of String)

    array_value = CrystalClick::BinaryValue.array(
      array_qbit,
      [w234p_qbit_value(0x11_u8)] of CrystalClick::BinaryValue,
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_qbit,
      [
        w234p_qbit_value(0x21_u8),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
      ] of CrystalClick::BinaryValue,
    )
    map_value = CrystalClick::BinaryValue.map(
      map_qbit,
      [CrystalClick::BinaryValue.string("key"), w234p_qbit_value(0x31_u8)] of CrystalClick::BinaryValue,
    )
    nested_row = CrystalClick::BinaryValue.tuple(
      CrystalClick::BinaryNestedType.tuple_for(nested_qbit),
      [w234p_qbit_value(0x41_u8)] of CrystalClick::BinaryValue,
    )
    nested_value = CrystalClick::BinaryValue.nested(nested_qbit, [nested_row] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array_qbit, [] of CrystalClick::BinaryValue)
    empty_map = CrystalClick::BinaryValue.map(map_qbit, [] of CrystalClick::BinaryValue)
    empty_nested = CrystalClick::BinaryValue.nested(nested_qbit, [] of CrystalClick::BinaryValue)

    first_fields = {
      "array"  => array_value,
      "map"    => map_value,
      "nested" => nested_value,
      "tuple"  => tuple_value,
    } of String => CrystalClick::BinaryValue
    second_fields = {
      "array"  => empty_array,
      "map"    => empty_map,
      "nested" => empty_nested,
      "tuple"  => tuple_value,
    } of String => CrystalClick::BinaryValue
    expected = [] of Hash(String, Bytes)
    [first_fields, second_fields].each do |fields|
      snapshots = Hash(String, Bytes).new
      fields.each do |path, value|
        snapshots[path] = CrystalClick::BinaryValueCodec.encode(value)
      end
      expected << snapshots
    end

    schema = CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )
    object_structure = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: 2_u64,
      bucket_count: 2_u64,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        object_structure,
        {} of String => CrystalClick::DynamicStructure,
      ),
      schema.typed_paths,
    )
    granules = [
      [CrystalClick::ObjectDocument.new(first_fields)] of CrystalClick::ObjectDocument,
      [CrystalClick::ObjectDocument.new(second_fields)] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    parent = File.tempname("crystal-click-w234-object-qbit-advanced-copy-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 1,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      full = reader.read_marks(0, 2)
      full.size.should eq(2)
      full.each_with_index do |mark, mark_index|
        mark.size.should eq(1)
        paths = ["array", "map", "nested", "tuple"] of String
        paths.each do |path|
          value = mark[0].value_for(path)
          CrystalClick::BinaryValueCodec.encode(value).should eq(expected[mark_index][path])
        end
      end
      reader.read_marks(2, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
