require "./spec_helper"
require "file_utils"
require "../scripts/support/static_recursive_selected_metadata_w258_fixture"

module CrystalClick::WidePartWriter
  # Re-sign test mutations with the production checksum writer. Metadata and
  # mark failures must not be masked by a stale selected-file size check.
  def self.w258_refresh_checksums(part : String) : Nil
    records = PartChecksums.open(part).entries.map do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      if entry.compressed
        raw = bytes.empty? ? bytes : CompressedBlock.decode_all(bytes)
        ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), true,
          raw.size.to_u64, CityHashV1.file_hash(raw))
      else
        ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(part, records)
  end
end

private def w258a_with_part(& : String ->)
  parent = File.tempname("crystal-click-w258-adversary-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    StaticRecursiveSelectedMetadataW258Fixture.write_part(part)
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w258a_info(name : String? = nil, children : Array(JSON::Any)? = nil) : JSON::Any
  fields = {
    "kind"         => JSON::Any.new("Default"),
    "num_defaults" => JSON::Any.new(0_i64),
    "num_rows"     => JSON::Any.new(8_i64),
  } of String => JSON::Any
  fields["name"] = JSON::Any.new(name.not_nil!) if name
  fields["subcolumns"] = JSON::Any.new(children.not_nil!) if children
  JSON::Any.new(fields)
end

private def w258a_set_records(part : String, records : Array(JSON::Any)) : Nil
  path = File.join(part, "serialization.json")
  info = JSON.parse(File.read(path))
  info.as_h["columns"] = JSON::Any.new(records)
  File.write(path, info.to_json)
  CrystalClick::WidePartWriter.w258_refresh_checksums(part)
end

private def w258a_assert_direct_readers(part : String) : Nil
  {"arr", "tup", "lc", "v"}.each do |name|
    reader = CrystalClick::WidePart.open_typed(part, name)
    reader.row_count.should eq(8_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
  end
end

private def w258a_assert_rejected_before_callback(part : String, error : T.class) : Nil forall T
  callbacks = 0
  expect_raises(T) do
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["arr", "pk"])
    table.scan_typed_window(8_u64, 1) { |_batch| callbacks += 1 }
  end
  callbacks.should eq(0)
end

describe "W258 selected metadata hostile boundary" do
  it "admits sparse Default records independently of key role and omission" do
    w258a_with_part do |part|
      w258a_set_records(part, [w258a_info("side"), w258a_info("u")] of JSON::Any)
      w258a_assert_direct_readers(part)

      records = [w258a_info("arr"), w258a_info("lc"), w258a_info("v"),
                 w258a_info("tup", [w258a_info, w258a_info] of JSON::Any)] of JSON::Any
      records.each { |record| record.as_h["exact_num_defaults"] = JSON::Any.new(true) }
      records.last["subcolumns"].as_a[0].as_h["exact_num_defaults"] = JSON::Any.new(false)
      w258a_set_records(part, records)
      w258a_assert_direct_readers(part)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["lc", "u", "tup", "arr", "pk", "v", "side"])
      keys = [] of UInt64
      table.scan_typed do |batch|
        batch.array_nullable_uint64s_for("arr").size.should eq(batch.values_for("pk").size)
        batch.tuple_rows_for("tup").size.should eq(batch.values_for("pk").size)
        batch.low_cardinality_strings_for("lc").size.should eq(batch.values_for("pk").size)
        batch.variant_string_uint64_for("v").size.should eq(batch.values_for("pk").size)
        keys.concat(batch.values_for("pk"))
      end
      keys.should eq([1001_u64, 1002_u64, 1003_u64, 1004_u64, 1005_u64, 1006_u64, 1007_u64, 1008_u64])
    end
  end

  it "does not make a UInt64 sibling a direct selected-column metadata requirement" do
    w258a_with_part do |part|
      path = File.join(part, "columns.txt")
      # Positive Int64 values have the same physical bytes here. This is a
      # selected-reader witness, not an expansion of table primary-key laws.
      schema = File.read(path).sub("`pk` UInt64", "`pk` Int64").sub("`u` UInt64", "`u` Int64")
      File.write(path, schema)
      CrystalClick::WidePartWriter.w258_refresh_checksums(part)
      w258a_assert_direct_readers(part)
    end
  end

  it "binds reordered physical columns and renamed selected streams without a seven-column allowlist" do
    parent = File.tempname("crystal-click-w258-renamed-")
    Dir.mkdir(parent)
    begin
      fixture = StaticRecursiveSelectedMetadataW258Fixture
      columns = fixture.columns.reverse
      columns << CrystalClick::WidePartColumn.binary_bulk("another", fixture.array_type, fixture.marks(fixture.array_rows))
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_columns(part, "different_key", StaticRecursiveSelectedMetadataW258Fixture::KEYS.to_unsafe.to_slice(8), columns,
        rows_per_mark: 2, profile: CrystalClick::BinaryBulkProfile.with_size_stream)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["another", "different_key", "tup", "lc", "v"])
      observed = [] of Array(UInt64?)
      table.scan_typed_window(2_u64, 2) do |batch|
        observed.concat(batch.array_nullable_uint64s_for("another").map(&.dup))
        batch.values_for("different_key").to_a.should eq([1003_u64, 1004_u64])
      end
      observed.should eq([[nil, 17_u64] of UInt64?, [23_u64] of UInt64?])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "matches recursive Tuple child information and optional exact flags to the actual tree" do
    parent = File.tempname("crystal-click-w258-deep-tuple-")
    Dir.mkdir(parent)
    begin
      fixture = StaticRecursiveSelectedMetadataW258Fixture
      inner = fixture.tuple_type
      type = CrystalClick::BinaryDataType.tuple([inner, CrystalClick::BinaryDataType.primitive("UInt64")], ["group", "tail"])
      rows = fixture.tuple_rows.map do |value|
        CrystalClick::BinaryValue.tuple(type, [value, CrystalClick::BinaryValue.uint64(99_u64)])
      end
      columns = fixture.columns
      columns << CrystalClick::WidePartColumn.binary_bulk("deep", type, fixture.marks(rows))
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_columns(part, "pk", StaticRecursiveSelectedMetadataW258Fixture::KEYS.to_unsafe.to_slice(8), columns,
        rows_per_mark: 2, profile: CrystalClick::BinaryBulkProfile.with_size_stream)
      nested = w258a_info(nil, [w258a_info, w258a_info] of JSON::Any)
      nested.as_h["exact_num_defaults"] = JSON::Any.new(true)
      w258a_set_records(part, [w258a_info("deep", [nested, w258a_info] of JSON::Any)] of JSON::Any)
      reader = CrystalClick::WidePart.open_typed(part, "deep")
      reader.read_tuple_mark_range("deep", 1, 1).row_count.should eq(2)

      nested.as_h["subcolumns"] = JSON::Any.new([] of JSON::Any)
      w258a_set_records(part, [w258a_info("deep", [nested, w258a_info] of JSON::Any)] of JSON::Any)
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(part, "deep") }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "hard-fails duplicate and unmapped names instead of retrying the old validator" do
    {"duplicate", "unmapped"}.each do |label|
      w258a_with_part do |part|
        records = label == "duplicate" ? [w258a_info("side"), w258a_info("side")] : [w258a_info("absent")]
        w258a_set_records(part, records)
        w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
      end
    end
  end

  it "checks mandatory common fields even on an unsupported serializer kind" do
    {"kind", "name", "num_defaults", "num_rows"}.each do |field|
      w258a_with_part do |part|
        record = w258a_info("side")
        record.as_h["kind"] = JSON::Any.new("Sparse")
        record.as_h.delete(field)
        w258a_set_records(part, [record] of JSON::Any)
        w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
      end
    end
  end

  it "rejects malformed counts and optional flags in unselected records" do
    mutations = [
      {"num_rows", JSON::Any.new(7_i64)},
      {"num_rows", JSON::Any.new(-1_i64)},
      {"num_defaults", JSON::Any.new(-1_i64)},
      {"num_defaults", JSON::Any.new(9_i64)},
      {"num_defaults", JSON::Any.new("0")},
      {"exact_num_defaults", JSON::Any.new(1_i64)},
    ] of Tuple(String, JSON::Any)
    mutations.each do |field, value|
      w258a_with_part do |part|
        record = w258a_info("side")
        record.as_h[field] = value
        w258a_set_records(part, [record] of JSON::Any)
        w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
      end
    end
  end

  it "keeps valid-but-unsupported kinds and Tuple shapes outside the new proof" do
    w258a_with_part do |part|
      record = w258a_info("side")
      record.as_h["kind"] = JSON::Any.new("Sparse")
      w258a_set_records(part, [record] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::UnsupportedFormatError)
    end
    w258a_with_part do |part|
      w258a_set_records(part, [w258a_info("tup", [w258a_info] of JSON::Any)] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::UnsupportedFormatError)
    end
  end

  it "does not turn malformed recursive child counts into an unsupported-profile retry" do
    {"Default", "Sparse"}.each do |kind|
      w258a_with_part do |part|
        child = w258a_info
        child.as_h["kind"] = JSON::Any.new(kind)
        child.as_h.delete("num_rows")
        w258a_set_records(part, [w258a_info("tup", [child, w258a_info] of JSON::Any)] of JSON::Any)
        w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
      end
    end
  end

  it "does not let a well-formed unproven record conceal later corrupt common fields" do
    w258a_with_part do |part|
      unproven = w258a_info("side")
      unproven.as_h["extra"] = JSON::Any.new(true)
      corrupt = w258a_info("u")
      corrupt.as_h["num_rows"] = JSON::Any.new(1_i64)
      w258a_set_records(part, [unproven, corrupt] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
    end
  end

  it "retains strict envelope version and propagation gates" do
    {"version", "propagate", "string_version", "columns"}.each do |label|
      w258a_with_part do |part|
        path = File.join(part, "serialization.json")
        info = JSON.parse(File.read(path))
        case label
        when "version"        then info.as_h["version"] = JSON::Any.new(2_i64)
        when "propagate"      then info.as_h["propagate_types_serialization_versions_to_nested_types"] = JSON::Any.new(false)
        when "string_version" then info["types_serialization_versions"].as_h["string"] = JSON::Any.new(2_i64)
        when "columns"        then info.as_h.delete("columns")
        end
        File.write(path, info.to_json)
        CrystalClick::WidePartWriter.w258_refresh_checksums(part)
        w258a_assert_rejected_before_callback(part, CrystalClick::UnsupportedFormatError)
      end
    end
  end

  it "does not let an earlier unproven record conceal corrupt Tuple child common fields" do
    w258a_with_part do |part|
      earlier = w258a_info("side")
      earlier.as_h["unknown_info"] = JSON::Any.new(true)
      malformed = w258a_info
      malformed.as_h.delete("num_rows")
      tuple = w258a_info("tup", [w258a_info, malformed] of JSON::Any)
      w258a_set_records(part, [earlier, tuple] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
    end
  end

  it "checks later Tuple child common fields before classifying an earlier child as unsupported" do
    {"kind", "shape"}.each do |label|
      w258a_with_part do |part|
        earlier = w258a_info
        if label == "kind"
          earlier.as_h["kind"] = JSON::Any.new("Sparse")
        else
          earlier.as_h["unknown_info"] = JSON::Any.new(true)
        end
        malformed = w258a_info
        malformed.as_h.delete("num_rows")
        w258a_set_records(part, [w258a_info("tup", [earlier, malformed] of JSON::Any)] of JSON::Any)
        expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(part, "tup") }
      end
    end
  end

  it "does not mistake an admitted whitespace Tuple declaration for shallow base information" do
    w258a_with_part do |part|
      type = "Tuple (n UInt64, s String)"
      CrystalClick::WidePart.supports_named_scalar_tuple_type?(type).should be_true
      path = File.join(part, "columns.txt")
      File.write(path, File.read(path).sub("Tuple(n UInt64, s String)", type))
      CrystalClick::WidePartWriter.w258_refresh_checksums(part)
      w258a_assert_direct_readers(part)
      w258a_set_records(part, [w258a_info("tup")] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::UnsupportedFormatError)
    end
  end

  it "checks recursive records for the full already-admitted Tuple grammar" do
    w258a_with_part do |part|
      path = File.join(part, "columns.txt")
      File.write(path, File.read(path).sub("Tuple(n UInt64, s String)", "Tuple (n UInt64, s String)"))
      CrystalClick::WidePartWriter.w258_refresh_checksums(part)
      children = [w258a_info, w258a_info] of JSON::Any
      w258a_set_records(part, [w258a_info("tup", children)] of JSON::Any)
      w258a_assert_direct_readers(part)
      children.last.as_h.delete("num_rows")
      w258a_set_records(part, [w258a_info("tup", children)] of JSON::Any)
      w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
    end
  end

  it "still rejects a selected stream length mutation before EOF callbacks" do
    w258a_with_part do |part|
      path = File.join(part, "#{CrystalClick::StreamName.hash("arr.size0")}.bin")
      bytes = File.read(path).to_slice
      File.write(path, bytes[0, bytes.size - 1])
      w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
    end
  end

  it "checks the complete cross-column mark grid even when the window is EOF" do
    w258a_with_part do |part|
      path = File.join(part, "#{CrystalClick::StreamName.hash("arr.size0")}.mrk2")
      bytes = File.read(path).to_slice.dup
      bytes[2 * 24 + 16] = 3_u8
      bytes[3 * 24 + 16] = 1_u8
      File.write(path, bytes)
      CrystalClick::WidePartWriter.w258_refresh_checksums(part)
      w258a_assert_rejected_before_callback(part, CrystalClick::CorruptPartError)
    end
  end
end
