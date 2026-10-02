require "./spec_helper"

private def w123_model_structure(paths : Array(String) = ["d"] of String) : CrystalClick::ObjectDynamicStructureSet
  dynamics = Hash(String, CrystalClick::DynamicStructure).new
  paths.each do |path|
    dynamics[path] = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
  end
  CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new(paths), dynamics)
end

describe "W123 Object document owners" do
  it "keeps raw path bytes exact, sorted, and detached from returned arrays" do
    nul = String.new(Bytes[0x61_u8, 0x00_u8])
    opaque = String.new(Bytes[0xff_u8])
    source = {
      "a.b"  => CrystalClick::BinaryValue.bool(true),
      opaque => CrystalClick::BinaryValue.string("opaque"),
      "a"    => CrystalClick::BinaryValue.uint64(7_u64),
      nul    => CrystalClick::BinaryValue.bool(false),
      ""     => CrystalClick::BinaryValue.string("empty path"),
    } of String => CrystalClick::BinaryValue

    document = CrystalClick::ObjectDocument.new(source)
    source["later"] = CrystalClick::BinaryValue.bool(true)

    document.paths.should eq(["", "a", nul, "a.b", opaque] of String)
    document.path_count.should eq(5)
    document.path_byte_size_at(2).should eq(2)
    document.path_byte_at(2, 0).should eq(0x61_u8)
    document.path_byte_at(2, 1).should eq(0x00_u8)
    document.has_path?(nul).should be_true
    document.has_path?("a").should be_true
    document.has_path?("a.b").should be_true
    document.has_path?("later").should be_false
    document.value_for("a").as_uint64.should eq(7_u64)

    detached = document.paths
    detached[0] = "changed"
    document.path_at(0).should eq("")
    expect_raises(KeyError) { document.value_for("missing") }
  end

  it "binds an exact disjoint typed schema without treating prefixes as collisions" do
    structures = w123_model_structure(["a"] of String)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    supplied = {"a.b" => uint64, "" => string} of String => CrystalClick::BinaryDataType

    plan = CrystalClick::ObjectDocumentPlan.new(structures, supplied)
    supplied["later"] = string
    plan.typed_path_count.should eq(2)
    plan.typed_path_at(0).should eq("")
    plan.typed_path_at(1).should eq("a.b")
    plan.typed_type_for("a.b").should eq(uint64)
    plan.has_typed_path?("a").should be_false
    plan.has_typed_path?("later").should be_false

    detached = plan.typed_paths
    detached["changed"] = string
    plan.typed_paths.keys.sort.should eq(["", "a.b"] of String)
    expect_raises(KeyError) { plan.typed_type_for("missing") }
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(structures, {"a" => uint64})
    end
  end

  it "retains malformed stream grids and lane rosters for decoder classification" do
    metadata = CrystalClick::ObjectDynamicStructureStreams.new(
      Bytes[0xff_u8],
      {"not-the-roster" => Bytes[0x00_u8]} of String => Bytes
    )
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes.empty,
      [] of CrystalClick::DynamicDiscriminatorMark
    )
    malformed_dynamic = CrystalClick::DynamicValueStreams.new(
      discriminator,
      {} of String => CrystalClick::BinaryBulkStreams
    )
    malformed_bulk = CrystalClick::BinaryBulkStreams.new(
      9,
      {
        "foreign.role" => CrystalClick::BinaryBulkStream.new(Bytes[0x01_u8], [2_u64]),
      } of String => CrystalClick::BinaryBulkStream
    )
    typed = {
      "z"   => malformed_bulk,
      "a.b" => CrystalClick::BinaryBulkStreams.new(0, {} of String => CrystalClick::BinaryBulkStream),
    } of String => CrystalClick::BinaryBulkStreams
    dynamic = {"foreign.path" => malformed_dynamic} of String => CrystalClick::DynamicValueStreams
    rows = [2_u64, 0_u64] of UInt64

    streams = CrystalClick::ObjectDocumentStreams.new(metadata, rows, typed, dynamic, malformed_bulk)
    typed["later"] = malformed_bulk
    dynamic.clear
    rows[0] = 99_u64

    streams.mark_count.should eq(2)
    streams.row_count_at(0).should eq(2_u64)
    streams.rows_per_mark.should eq([2_u64, 0_u64])
    streams.typed_path_count.should eq(2)
    streams.typed_paths.should eq(["a.b", "z"] of String)
    streams.has_typed_path?("later").should be_false
    streams.has_typed_path?("z").should be_true
    streams.typed_for("z").mark_count.should eq(9)
    streams.dynamic_path_count.should eq(1)
    streams.dynamic_paths.should eq(["foreign.path"] of String)
    streams.dynamic_for("foreign.path").should eq(malformed_dynamic)
    streams.shared.mark_count.should eq(9)

    copied_rows = streams.rows_per_mark
    copied_rows[0] = 7_u64
    streams.row_count_at(0).should eq(2_u64)
    expect_raises(KeyError) { streams.dynamic_for("missing") }
  end
end
