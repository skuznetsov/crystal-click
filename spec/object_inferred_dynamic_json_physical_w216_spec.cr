require "file_utils"
require "./spec_helper"

private alias W216PLeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w216p_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w216p_json(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w216p_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w216p_mark_rows(marks : Bytes) : Array(UInt64)
  record_size = CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  raise "W216 .mrk2 fixture has a partial record" unless marks.size % record_size == 0
  Array(UInt64).new(marks.size // record_size) do |record|
    offset = record * record_size + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w216p_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

module CrystalClick::WidePartWriter
  def self.w216p_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = if bytes.empty?
                raise "W216 empty compressed entry has a nonzero raw extent" unless entry.uncompressed_size == 0_u64
                Bytes.empty
              else
                CompressedBlock.decode_all(bytes)
              end
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, CityHashV1.file_hash(raw)
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    write_checksums(part, records)
  end
end

private def w216p_signature(document : CrystalClick::ObjectDocument) : String
  return "ABSENT" unless document.has_path?("payload")
  value = document.value_for("payload")
  return "NULL" if value.is_null?
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_JSON
    typed = value.json_row.value_for("v").not_nil!
    expected = CrystalClick::BinaryDataType.primitive("UInt8")
    raise "W216 direct JSON v path changed its exact type" unless typed.type == expected
    "JSON(#{typed.byte_at(0)})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    elements = value.elements.map do |element|
      raise "W216 Array(JSON) contains a non-JSON element" unless element.type == w216p_json_type
      typed = element.json_row.value_for("v").not_nil!
      expected = CrystalClick::BinaryDataType.primitive("UInt8")
      raise "W216 Array(JSON) v path changed its exact type" unless typed.type == expected
      "JSON(#{typed.byte_at(0)})"
    end
    "ARRAY[#{elements.join(",")}]"
  else
    raise "W216 payload has an unrostered root actual type: #{value.type.name}"
  end
end

private def w216p_array_json_q(fixture : W216PhysicalFixture, mark_index : Int32) : UInt64
  array_json = CrystalClick::BinaryDataType.array(w216p_json_type)
  fixture.granules[mark_index].sum(0_u64) do |document|
    next 0_u64 unless document.has_path?("payload")
    value = document.value_for("payload")
    if !value.is_null? && value.type == array_json
      value.elements.size.to_u64
    else
      0_u64
    end
  end
end

private struct W216PhysicalFixture
  getter schema : CrystalClick::ObjectDocumentSchema
  getter plan : CrystalClick::ObjectDocumentPlan
  getter child_plan : CrystalClick::ObjectDocumentPlan
  getter granules : Array(Array(CrystalClick::ObjectDocument))
  getter expected : Array(Array(String))

  def initialize
    json = w216p_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    string = CrystalClick::BinaryDataType.primitive("String")
    child = CrystalClick::ObjectDocumentPlan.new(w216p_empty_structures, json.json_type.not_nil!.typed_paths)
    @child_plan = child
    payload_roster = CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType)
    label_roster = CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload", "label"] of String),
      {"payload" => payload_roster, "label" => label_roster} of String => CrystalClick::DynamicStructure,
    )
    @schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    @plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      @schema.typed_paths,
      root_dynamic_json_object_leaf_plans: {
        "payload" => [
          {
            CrystalClick::BinaryDynamicJsonLeafKey.new(
              "root", payload_roster.canonical_index_for(json), [] of Int32,
            ),
            child,
          },
          {
            CrystalClick::BinaryDynamicJsonLeafKey.new(
              "root", payload_roster.canonical_index_for(array_json), [0_i32] of Int32,
            ),
            child,
          },
        ] of W216PLeafPlan,
      } of String => Array(W216PLeafPlan),
    )

    direct = ->(value : UInt8) { w216p_json(json, value) }
    array = ->(values : Array(UInt8)) {
      CrystalClick::BinaryValue.array(
        array_json,
        values.map { |value| direct.call(value) },
      )
    }
    row = ->(payload : CrystalClick::BinaryValue?, label : String?) {
      entries = {} of String => CrystalClick::BinaryValue
      entries["payload"] = payload.not_nil! if payload
      entries["label"] = CrystalClick::BinaryValue.string(label.not_nil!) if label
      CrystalClick::ObjectDocument.new(entries)
    }
    @granules = [
      [
        row.call(direct.call(7_u8), "ordinary-first"),
        row.call(array.call([8_u8, 9_u8] of UInt8), nil),
      ] of CrystalClick::ObjectDocument,
      [
        row.call(nil, "payload-absent"),
        row.call(CrystalClick::BinaryValue.null, "payload-null"),
      ] of CrystalClick::ObjectDocument,
      [
        row.call(direct.call(10_u8), nil),
        row.call(array.call([] of UInt8), nil),
      ] of CrystalClick::ObjectDocument,
      [
        row.call(array.call([11_u8] of UInt8), "final-array"),
        row.call(direct.call(12_u8), nil),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
    @expected = [
      ["JSON(7)", "ARRAY[JSON(8),JSON(9)]"] of String,
      ["ABSENT", "ABSENT"] of String,
      ["JSON(10)", "ARRAY[]"] of String,
      ["ARRAY[JSON(11)]", "JSON(12)"] of String,
    ] of Array(String)
  end
end

private def w216p_direct_json_value_stream_name(
  fixture : W216PhysicalFixture,
  profile : CrystalClick::BinaryBulkProfile,
) : String
  prefix = CrystalClick::PhysicalStreamName.escape("payload")
  prefix = CrystalClick::PhysicalStreamName.append_escaped_component(prefix, "payload")
  prefix = CrystalClick::PhysicalStreamName.append_escaped_component(prefix, w216p_json_type.name)
  child_physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix,
    fixture.child_plan,
    profile,
    typed_descriptor_root_depth: 2,
  )
  child_physical.typed("v").stream_name_for("root.data")
end

private def w216p_append_unconsumed_child_byte(
  part : String,
  stream : String,
  mark_index : Int32 = 3,
  expected_physical_rows : UInt64? = nil,
) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice)
  marks = File.read(marks_path).to_slice
  record_size = CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  raise "W216 child fixture has a partial mark record" unless marks.size % record_size == 0
  record_count = marks.size // record_size
  raise "W216 child fixture is missing a terminal mark" unless record_count == 5
  raise "W216 child fixture does not fit one frame" if raw.size >= 64

  rows = Array(UInt64).new(record_count - 1) do |record|
    offset = record * record_size + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
  if mark_index < 0 || mark_index >= rows.size
    raise "W216 child corruption target mark is outside its row grid"
  end
  if expected = expected_physical_rows
    raise "W216 child corruption target has an unexpected P count" unless rows[mark_index] == expected
  end

  offsets = Array(UInt64).new(record_count)
  (0...record_count - 1).each do |record|
    compressed_offset = 0_u64
    8.times { |index| compressed_offset |= marks[record * record_size + index].to_u64 << (index * 8) }
    raise "W216 child fixture unexpectedly spans compressed frames" unless compressed_offset == 0_u64
    offset = 0_u64
    8.times { |index| offset |= marks[record * record_size + 8 + index].to_u64 << (index * 8) }
    offsets << offset
  end

  # Place a valid UInt8 body byte after the target mark's expected child values.
  # Later logical offsets move by one; P rows and the separately encoded Q
  # schedule stay intact. Recompression keeps the transport valid, so a decoder
  # that skips this mark cannot observe the surplus byte.
  insert_at = if mark_index + 1 < offsets.size
                offsets[mark_index + 1].to_i
              else
                raw.size
              end
  corrupted = Bytes.new(raw.size + 1)
  raw.each_with_index do |byte, index|
    corrupted[index < insert_at ? index : index + 1] = byte
  end
  corrupted[insert_at] = 0x7f_u8
  offsets.map! do |offset|
    offset >= insert_at.to_u64 ? offset + 1_u64 : offset
  end
  offsets << corrupted.size.to_u64
  pair = CrystalClick::CompressedMarkWriter.encode(
    corrupted,
    offsets,
    rows,
    frame_bytes: 64,
  )
  File.write(data_path, pair.data)
  File.write(marks_path, pair.marks)
  CrystalClick::WidePartWriter.w216p_refresh_checksums(part)
end

private def w216p_array_json_value_stream_name(
  fixture : W216PhysicalFixture,
  profile : CrystalClick::BinaryBulkProfile,
) : String
  array_json = CrystalClick::BinaryDataType.array(w216p_json_type)
  roster = fixture.plan.structures.dynamic_for("payload")
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root", roster.canonical_index_for(array_json), [0_i32] of Int32,
  )
  physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", fixture.plan, profile)
  site = physical.root_dynamic_json("payload").json_object_site(key)
  site.physical_plan.typed("v").stream_name_for("root.data")
end

private def w216p_with_parent(&)
  parent = File.tempname("crystal-click-w216-inferred-json-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W216 inferred Object Dynamic JSON physical readers" do
  it "admits only a complete same-operation root JSON arm at the physical plan factory" do
    json = w216p_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    ordinary = CrystalClick::BinaryDataType.primitive("UInt8")
    structure = CrystalClick::DynamicStructure.new(
      [array_json, ordinary] of CrystalClick::BinaryDataType,
    )
    json_arm_index = structure.canonical_index_for(array_json)
    leaf_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", json_arm_index, [0_i32] of Int32,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      w216p_empty_structures,
      json.json_type.not_nil!.typed_paths,
    )
    leaf_plans = [{leaf_key, child_plan}] of W216PLeafPlan
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 16,
      max_nodes: 100_000,
      max_elements: 100_000,
      max_bytes: 1_000_000,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    roster = CrystalClick::DynamicJsonObjectBindingRoster.for_root(
      structure, leaf_plans, budget,
    )

    physical = CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
      array_json,
      json_arm_index,
      roster,
      budget,
      "payload",
      limits: limits,
    )
    # JSON leaf lanes belong to its bound child Object plan. The root arm
    # factory admits only the Array wrapper's ordinary sizes role here.
    physical.stream_names.should eq({"root.sizes" => "payload.size0"} of String => String)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(array_json, "payload")
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(array_json, "payload")
    end

    ordinary_arm_index = structure.canonical_index_for(ordinary)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
        array_json,
        ordinary_arm_index,
        roster,
        budget,
        "payload",
        limits: limits,
      )
    end

    other_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {
        "other" => CrystalClick::BinaryDataType.primitive("UInt8"),
      } of String => CrystalClick::BinaryDataType,
    )
    wrong_type = CrystalClick::BinaryDataType.array(other_json)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
        wrong_type,
        json_arm_index,
        roster,
        budget,
        "payload",
        limits: limits,
      )
    end

    foreign_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
        array_json,
        json_arm_index,
        roster,
        foreign_budget,
        "payload",
        limits: limits,
      )
    end

    different_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 15,
      max_nodes: 100_000,
      max_elements: 100_000,
      max_bytes: 1_000_000,
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
        array_json,
        json_arm_index,
        roster,
        budget,
        "payload",
        limits: different_limits,
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkPhysicalPlan.for_root_json_arm(
        array_json,
        json_arm_index,
        roster,
        budget,
        "payload",
        limits: limits,
        context: CrystalClick::PhysicalStreamPlanContext.new(different_limits),
      )
    end
  end

  it "discovers exact JSON child bindings for full, windowed, column, and table reads" do
    fixture = W216PhysicalFixture.new
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    modes = [
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    ] of UInt64

    w216p_with_parent do |parent|
      part_index = 0
      profiles.each do |profile|
        modes.each do |mode|
          part_index += 1
          part = File.join(parent, "all_#{part_index}_#{part_index}_0")
          CrystalClick::WidePartWriter.write_uint64_object_pair(
            part,
            "pk",
            Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
            "payload",
            fixture.schema,
            fixture.plan,
            fixture.granules,
            rows_per_mark: 2,
            mode: mode,
            profile: profile,
            frame_bytes: 64,
          ).should eq(part)

          File.read(File.join(part, "count.txt")).should eq("8")
          reader = CrystalClick::ObjectColumnReader.open(part, "payload", fixture.schema)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
          physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", fixture.plan, profile)
          reader.physical_stream_names.should eq(physical.stream_names)
          physical.stream_names.each do |stream|
            marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
            w216p_mark_rows(File.read(marks_path).to_slice).should eq([2_u64, 2_u64, 2_u64, 2_u64, 0_u64])
          end

          full = CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            fixture.schema.typed_paths,
            first_mark: 0,
            mark_count: 4,
            profile: profile,
            hashed: true,
          )
          full.map { |mark| mark.map { |document| w216p_signature(document) } }.should eq(fixture.expected)
          CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", fixture.schema.typed_paths,
            first_mark: 0, mark_count: 0, profile: profile, hashed: true,
          ).should be_empty
          CrystalClick::ObjectDocumentFileReader.read(
            part, "payload", fixture.schema.typed_paths,
            first_mark: 4, mark_count: 0, profile: profile, hashed: true,
          ).should be_empty
          full_reader = reader.read_marks(0, 4)
          full_reader.map { |mark| mark.map { |document| w216p_signature(document) } }.should eq(fixture.expected)
          reader.read_marks(4, 0).should be_empty

          table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
          table.total_row_count.should eq(8_u64)
          table_all = [] of Array(String)
          table.scan_typed do |batch|
            batch.object_documents_for("payload").each do |document|
              table_all << [w216p_signature(document)]
            end
          end
          table_all.should eq(fixture.expected.flat_map { |mark| mark.map { |signature| [signature] } })

          table_middle = [] of Array(String)
          table.scan_typed_window(2_u64, 4) do |batch|
            batch.object_documents_for("payload").each do |document|
              table_middle << [w216p_signature(document)]
            end
          end
          table_middle.should eq(fixture.expected[1, 2].flat_map { |mark| mark.map { |signature| [signature] } })
          table_final = [] of Array(String)
          table.scan_typed_window(6_u64, 2) do |batch|
            batch.object_documents_for("payload").each do |document|
              table_final << [w216p_signature(document)]
            end
          end
          table_final.should eq(fixture.expected[3, 1].flat_map { |mark| mark.map { |signature| [signature] } })
          table.scan_typed_window(8_u64, 1) { raise "EOF table window unexpectedly materialized a batch" }
        end
      end
    end
  end

  it "reopens repeated inferred-JSON child Objects across full, selected, and EOF reads" do
    nested_json = w216p_json_type
    outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
    )
    nested_child_plan = CrystalClick::ObjectDocumentPlan.new(
      w216p_empty_structures,
      nested_json.json_type.not_nil!.typed_paths,
    )
    nested_roster = CrystalClick::DynamicStructure.new([nested_json] of CrystalClick::BinaryDataType)
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["nested"] of String),
      {"nested" => nested_roster} of String => CrystalClick::DynamicStructure,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      outer_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: {
        "nested" => [{
          CrystalClick::BinaryDynamicJsonLeafKey.new(
            "root", nested_roster.canonical_index_for(nested_json), [] of Int32,
          ),
          nested_child_plan,
        }] of W216PLeafPlan,
      } of String => Array(W216PLeafPlan),
    )
    payload_roster = CrystalClick::DynamicStructure.new([outer_json] of CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload"] of String),
      {"payload" => payload_roster} of String => CrystalClick::DynamicStructure,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      root_dynamic_json_object_leaf_plans: {
        "payload" => [{
          CrystalClick::BinaryDynamicJsonLeafKey.new(
            "root", payload_roster.canonical_index_for(outer_json), [] of Int32,
          ),
          child_plan,
        }] of W216PLeafPlan,
      } of String => Array(W216PLeafPlan),
    )
    row_for = ->(value : UInt8) {
      nested_value = w216p_json(nested_json, value)
      outer_value = CrystalClick::BinaryValue.json(
        outer_json,
        CrystalClick::BinaryJsonRow.new(
          outer_json,
          [{"nested", nested_value}] of Tuple(String, CrystalClick::BinaryValue),
        ),
      )
      CrystalClick::ObjectDocument.new({"payload" => outer_value} of String => CrystalClick::BinaryValue)
    }
    granules = [
      [row_for.call(33_u8)] of CrystalClick::ObjectDocument,
      [row_for.call(44_u8)] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    w216p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[101_u64, 102_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 1,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      ).should eq(part)

      full = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 0,
        mark_count: 2,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true,
      )
      nested_values = ->(marks : Array(Array(CrystalClick::ObjectDocument))) {
        marks.map do |mark|
          mark.map do |document|
            outer = document.value_for("payload")
            nested = outer.json_row.value_for("nested").not_nil!
            nested.json_row.value_for("v").not_nil!.byte_at(0)
          end
        end
      }
      nested_values.call(full).should eq([[33_u8] of UInt8, [44_u8] of UInt8])

      selected = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 1,
        mark_count: 1,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true,
      )
      nested_values.call(selected).should eq([[44_u8] of UInt8])

      eof = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 2,
        mark_count: 0,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true,
      )
      eof.should be_empty
    end
  end

  it "validates a nonempty JSON child mark outside the selected window and at EOF" do
    fixture = W216PhysicalFixture.new
    w216p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
        "payload",
        fixture.schema,
        fixture.plan,
        fixture.granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
        "payload", fixture.plan, CrystalClick::BinaryBulkProfile.single_stream,
      )
      child_structure = physical.stream_names.find do |name|
        name != physical.object_structure_stream && name.ends_with?(".object_structure")
      end.not_nil!
      marks_path = File.join(part, "#{CrystalClick::StreamName.hash(child_structure)}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # Parent marks retain P=2 even when the logical selected JSON-child count
      # Q varies; corrupt a final physical parent record where both direct and
      # Array(JSON) children are nonempty. The selected first mark has Q=1,
      # so rejecting this fixture requires full-domain child metadata checks.
      w216p_write_u64(marks, CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE * 3 + 16, 1_u64)
      File.write(marks_path, marks)
      CrystalClick::WidePartWriter.w216p_refresh_checksums(part)

      [{0, 1}, {4, 0}].each do |window|
        first_mark, mark_count = window
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            fixture.schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            profile: CrystalClick::BinaryBulkProfile.single_stream,
            hashed: true,
          )
        end
        error.to_s.should contain("Object site row grid differs from its parent physical grid")
      end
    end
  end

  it "decodes the complete excluded child value body even when its mark grid is valid" do
    fixture = W216PhysicalFixture.new
    w216p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
        "payload",
        fixture.schema,
        fixture.plan,
        fixture.granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 64,
      )
      child_value_stream = w216p_direct_json_value_stream_name(
        fixture, CrystalClick::BinaryBulkProfile.single_stream,
      )
      w216p_append_unconsumed_child_byte(part, child_value_stream)

      # The selected first mark remains valid. Only a full JSON-child value
      # decode reaches the extra byte in final Q=1; EOF must also validate it.
      [{0, 1}, {4, 0}].each do |window|
        first_mark, mark_count = window
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            fixture.schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            profile: CrystalClick::BinaryBulkProfile.single_stream,
            hashed: true,
          )
        end
        error.to_s.should contain("binary codec input has trailing bytes")
      end
    end
  end

  it "decodes excluded Array(JSON) child values when Q differs from parent P" do
    fixture = W216PhysicalFixture.new
    profile = CrystalClick::BinaryBulkProfile.single_stream
    w216p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
        "payload",
        fixture.schema,
        fixture.plan,
        fixture.granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        profile: profile,
        frame_bytes: 64,
      )

      clean = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        fixture.schema.typed_paths,
        first_mark: 0,
        mark_count: 4,
        profile: profile,
        hashed: true,
      )
      clean.map { |mark| mark.map { |document| w216p_signature(document) } }.should eq(fixture.expected)

      array_child_value_stream = w216p_array_json_value_stream_name(fixture, profile)
      w216p_array_json_q(fixture, 0).should eq(2_u64)
      w216p_array_json_q(fixture, 3).should eq(1_u64)
      # The first parent mark has P=2 and this Array(JSON) child has Q=2.
      # Insert one surplus UInt8 after those two bodies, keeping Q and the
      # complete compressed/mark grid valid. A selected-only read of final
      # mark 3 sees only its Q=1 body and skips this excluded mark; full-domain
      # validation must reject the trailing byte in mark 0, including at EOF.
      w216p_append_unconsumed_child_byte(
        part, array_child_value_stream, mark_index: 0, expected_physical_rows: 2_u64)

      [{3, 1}, {4, 0}].each do |window|
        first_mark, mark_count = window
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            fixture.schema.typed_paths,
            first_mark: first_mark,
            mark_count: mark_count,
            profile: profile,
            hashed: true,
          )
        end
        error.to_s.should contain("binary codec input has trailing bytes")
      end
    end
  end
end
