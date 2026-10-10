require "./spec_helper"
require "../scripts/support/schema_wide_part_w245_fixture"
require "file_utils"

private def w257_with_parent(&)
  parent = File.tempname("crystal-click-w257-bound-writer-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w257_target_roster : Array(Tuple(String, String))
  [
    {"pk", "UInt64"},
    {SchemaWidePartW245Fixture::STATE_NAME, SchemaWidePartW245Fixture::STATE_DECLARATION},
    {SchemaWidePartW245Fixture::DYNAMIC_NAME, SchemaWidePartW245Fixture::DYNAMIC_DECLARATION},
    {SchemaWidePartW245Fixture::OBJECT_NAME, SchemaWidePartW245Fixture::OBJECT_DECLARATION},
    {SchemaWidePartW245Fixture::RECURSIVE_NAME, SchemaWidePartW245Fixture::RECURSIVE_DECLARATION},
  ] of Tuple(String, String)
end

private def w257_write_bound(
  destination : String,
  binding : CrystalClick::WidePartSchemaBinding,
  columns : Array(CrystalClick::WidePartColumn),
  key_name : String = "pk",
) : String
  keys = SchemaWidePartW245Fixture::KEYS
  CrystalClick::WidePartWriter.write_uint64_columns(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: SchemaWidePartW245Fixture::ROWS_PER_MARK,
    profile: SchemaWidePartW245Fixture.profile("single"),
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    mode: SchemaWidePartW245Fixture.mode("basic"),
    frame_bytes: SchemaWidePartW245Fixture::FRAME_BYTES,
    schema_binding: binding,
  )
end

private def w257_expected_columns(roster : Array(Tuple(String, String))) : String
  String.build do |io|
    io << "columns format version: 1\n" << roster.size << " columns:\n"
    roster.each do |name, declaration|
      io << '`' << name << "` " << declaration << '\n'
    end
  end
end

describe CrystalClick::WidePartSchemaBinding do
  it "snapshots and returns detached ordered target rosters" do
    input = w257_target_roster
    binding = CrystalClick::WidePartSchemaBinding.new("pk", input)

    input[1] = {"changed", "String"}
    binding.columns.should eq(w257_target_roster)

    returned = binding.columns
    returned[1] = {"also_changed", "UInt8"}
    binding.columns.should eq(w257_target_roster)
    binding.key_name.should eq("pk")
  end

  it "rejects malformed key-first and duplicate target rosters" do
    expect_raises(ArgumentError) do
      CrystalClick::WidePartSchemaBinding.new("pk", [
        {"value", "UInt64"}, {"pk", "String"},
      ] of Tuple(String, String))
    end

    expect_raises(ArgumentError) do
      CrystalClick::WidePartSchemaBinding.new("pk", [
        {"pk", "UInt64"}, {"value", "String"}, {"value", "UInt8"},
      ] of Tuple(String, String))
    end
  end

  it "binds all four existing writer owner families to one exact target roster" do
    roster = w257_target_roster
    binding = CrystalClick::WidePartSchemaBinding.new("pk", roster)
    columns = SchemaWidePartW245Fixture.columns(
      SchemaWidePartW245Fixture.profile("single"),
      SchemaWidePartW245Fixture.mode("basic"),
    )

    w257_with_parent do |parent|
      destination = File.join(parent, "all_1_1_0")
      w257_write_bound(destination, binding, columns).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should eq(w257_expected_columns(roster))
    end
  end

  it "rejects changed key, name, type, order, missing, and extra columns before publication" do
    columns = SchemaWidePartW245Fixture.columns(
      SchemaWidePartW245Fixture.profile("single"),
      SchemaWidePartW245Fixture.mode("basic"),
    )
    valid = w257_target_roster
    wrong_key = [{"id", "UInt64"}] of Tuple(String, String)
    wrong_key.concat(valid[1..])
    wrong_name = valid.dup
    wrong_name[1] = {"renamed_state", wrong_name[1][1]}
    wrong_type = valid.dup
    wrong_type[1] = {
      wrong_type[1][0],
      "Tuple(label LowCardinality(String), total AggregateFunction(sum, UInt16))",
    }
    wrong_order = valid.dup
    wrong_order[2], wrong_order[3] = wrong_order[3], wrong_order[2]
    missing = valid[0..3]
    extra = valid.dup
    extra << {"extra", "UInt8"}

    bad_bindings = [
      CrystalClick::WidePartSchemaBinding.new("id", wrong_key),
      CrystalClick::WidePartSchemaBinding.new("pk", wrong_name),
      CrystalClick::WidePartSchemaBinding.new("pk", wrong_type),
      CrystalClick::WidePartSchemaBinding.new("pk", wrong_order),
      CrystalClick::WidePartSchemaBinding.new("pk", missing),
      CrystalClick::WidePartSchemaBinding.new("pk", extra),
    ]

    w257_with_parent do |parent|
      bad_bindings.each_with_index do |binding, index|
        destination = File.join(parent, "all_1_1_#{index}")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w257_write_bound(destination, binding, columns)
        end
        File.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end
    end
  end
end

describe CrystalClick::WidePartTransformOutput do
  it "retains copied keys and owner containers and returns detached arrays" do
    source_keys = [1_u64, 2_u64]
    source_columns = [CrystalClick::WidePartColumn.binary_bulk(
      "value",
      CrystalClick::BinaryDataType.primitive("UInt64"),
      [
        [CrystalClick::BinaryValue.uint64(10_u64)] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.uint64(20_u64)] of CrystalClick::BinaryValue,
      ],
    )]
    output = CrystalClick::WidePartTransformOutput.new(
      source_keys.to_unsafe.to_slice(source_keys.size), source_columns
    )

    source_keys[0] = 9_u64
    source_columns.clear
    output.keys.should eq([1_u64, 2_u64])
    output.columns.size.should eq(1)

    detached_keys = output.keys
    detached_keys[1] = 8_u64
    detached_columns = output.columns
    detached_columns.clear
    output.keys.should eq([1_u64, 2_u64])
    output.columns.size.should eq(1)
  end
end
