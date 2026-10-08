require "./spec_helper"
require "file_utils"

private def with_w218_part(label : String, & : String ->)
  parent = File.tempname("crystal-click-w218-recursive-tuple-#{label}-")
  Dir.mkdir(parent)
  yield File.join(parent, "all_1_1_0")
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w218_json_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
end

private def w218_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w218_direct_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse("Tuple(doc JSON(t UInt8), n UInt64)")
end

private def w218_nested_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Tuple(group Tuple(doc JSON(t UInt8), inner UInt64), tail UInt64)"
  )
end

private def w218_bulk_tuple_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Tuple(doc JSON(t UInt8), stats Tuple(x UInt64, y String))"
  )
end

private def w218_bulk_array_tuple_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Tuple(doc JSON(t UInt8), stats Tuple(items Array(Tuple(x UInt64, y UInt64)), tail UInt64))"
  )
end

private def w218_root_array_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse("Array(Tuple(doc JSON(t UInt8), inner UInt64))")
end

private def w218_document(value : UInt8) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value]
    ),
  } of String => CrystalClick::BinaryValue)
end

private def w218_direct_row(value : UInt8, number : UInt64) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w218_document(value)),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(number)),
  ] of CrystalClick::StorageColumnValue)
end

private def w218_nested_row(
  value : UInt8,
  inner : UInt64,
  tail : UInt64,
) : CrystalClick::StorageColumnValue
  group = CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w218_document(value)),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(inner)),
  ] of CrystalClick::StorageColumnValue)
  CrystalClick::StorageColumnValue.tuple([
    group,
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(tail)),
  ] of CrystalClick::StorageColumnValue)
end

private def w218_bulk_tuple_row(
  schema : CrystalClick::StorageColumnSchema,
  document : UInt8,
  x : UInt64,
  y : String,
) : CrystalClick::StorageColumnValue
  stats_type = schema.child_at(1).bulk_type
  stats = CrystalClick::BinaryValue.tuple(
    stats_type,
    [
      CrystalClick::BinaryValue.uint64(x),
      CrystalClick::BinaryValue.string(y),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w218_document(document)),
    CrystalClick::StorageColumnValue.bulk(stats),
  ] of CrystalClick::StorageColumnValue)
end

private def w218_bulk_array_tuple_row(
  schema : CrystalClick::StorageColumnSchema,
  document : UInt8,
  values : Array({UInt64, UInt64}),
  tail : UInt64,
) : CrystalClick::StorageColumnValue
  stats_type = schema.child_at(1).bulk_type
  array_type = stats_type.child_at(0)
  item_type = array_type.child_at(0)
  items = values.map do |pair|
    CrystalClick::BinaryValue.tuple(
      item_type,
      [
        CrystalClick::BinaryValue.uint64(pair[0]),
        CrystalClick::BinaryValue.uint64(pair[1]),
      ] of CrystalClick::BinaryValue,
    )
  end
  stats = CrystalClick::BinaryValue.tuple(
    stats_type,
    [
      CrystalClick::BinaryValue.array(array_type, items),
      CrystalClick::BinaryValue.uint64(tail),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w218_document(document)),
    CrystalClick::StorageColumnValue.bulk(stats),
  ] of CrystalClick::StorageColumnValue)
end

private def w218_root_array_rows : Array(CrystalClick::StorageColumnValue)
  item = CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w218_document(41_u8)),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(410_u64)),
  ] of CrystalClick::StorageColumnValue)
  [
    CrystalClick::StorageColumnValue.array([item] of CrystalClick::StorageColumnValue),
    CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue
end

private def w218_write_part(
  part : String,
  schema : CrystalClick::StorageColumnSchema,
  rows : Array(CrystalClick::StorageColumnValue),
) : Nil
  object_plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
  schema.each_json_site do |key, site_schema|
    object_plans[key] = w218_object_plan(site_schema)
  end

  granules = [
    [rows[0], rows[1]] of CrystalClick::StorageColumnValue,
    [rows[2]] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
  published = CrystalClick::WidePartWriter.write_uint64_recursive_pair(
    part,
    "pk",
    Slice[101_u64, 202_u64, 303_u64],
    "payload",
    schema,
    object_plans,
    granules,
    rows_per_mark: 2,
  )
  raise "W218 recursive fixture writer published to an unexpected path" unless published == part
  nil
end

private def w218_write_direct_part(part : String) : Nil
  w218_write_part(
    part,
    w218_direct_schema,
    [
      w218_direct_row(3_u8, 30_u64),
      w218_direct_row(5_u8, 50_u64),
      w218_direct_row(7_u8, 70_u64),
    ] of CrystalClick::StorageColumnValue,
  )
end

private def w218_write_nested_part(part : String) : Nil
  w218_write_part(
    part,
    w218_nested_schema,
    [
      w218_nested_row(9_u8, 90_u64, 900_u64),
      w218_nested_row(19_u8, 190_u64, 1900_u64),
      w218_nested_row(29_u8, 290_u64, 2900_u64),
    ] of CrystalClick::StorageColumnValue,
  )
end

private def w218_scalar_info(
  rows : Int64 = 3_i64,
  defaults : Int64 = 0_i64,
  kind : String = "Default",
  exact : Bool? = true,
) : JSON::Any
  fields = {
    "kind"         => JSON::Any.new(kind),
    "num_defaults" => JSON::Any.new(defaults),
    "num_rows"     => JSON::Any.new(rows),
  } of String => JSON::Any
  unless exact.nil?
    fields["exact_num_defaults"] = JSON::Any.new(exact.not_nil!)
  end
  JSON::Any.new(fields)
end

private def w218_tuple_info(
  rows : Int64,
  subcolumns : Array(JSON::Any),
  defaults : Int64 = 0_i64,
  exact : Bool? = true,
) : JSON::Any
  fields = w218_scalar_info(rows, defaults, exact: exact).as_h
  fields["subcolumns"] = JSON::Any.new(subcolumns)
  JSON::Any.new(fields)
end

private def w218_attach_payload_info(
  part : String,
  subcolumns : Array(JSON::Any)? = nil,
  root_exact : Bool? = nil,
  key_exact : Bool? = nil,
) : Nil
  serialization_path = File.join(part, "serialization.json")
  serialization = JSON.parse(File.read(serialization_path))
  payload = {
    "kind"         => JSON::Any.new("Default"),
    "name"         => JSON::Any.new("payload"),
    "num_defaults" => JSON::Any.new(0_i64),
    "num_rows"     => JSON::Any.new(3_i64),
  } of String => JSON::Any
  payload["exact_num_defaults"] = JSON::Any.new(root_exact.not_nil!) unless root_exact.nil?
  payload["subcolumns"] = JSON::Any.new(subcolumns.not_nil!) unless subcolumns.nil?
  serialization["columns"].as_a << JSON::Any.new(payload)
  unless key_exact.nil?
    key_entry = serialization["columns"].as_a.find do |entry|
      entry["name"]?.try(&.as_s) == "pk"
    end || raise "W218 fixture is missing its primary-key serializer"
    key_entry.as_h["exact_num_defaults"] = JSON::Any.new(key_exact.not_nil!)
  end
  File.write(serialization_path, serialization.to_json)
  CrystalClick::WidePartWriter.w218_refresh_checksums(part)
end

private def w218_leaf_subcolumns : Array(JSON::Any)
  [w218_scalar_info, w218_scalar_info] of JSON::Any
end

private def w218_expect_rejected(
  part : String,
  schema : CrystalClick::StorageColumnSchema = w218_direct_schema,
) : Nil
  begin
    CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
    raise "malformed recursive Tuple serialization metadata was accepted"
  rescue ex : CrystalClick::UnsupportedFormatError | CrystalClick::CorruptPartError
    # Both are closed rejection outcomes for malformed or unsupported metadata.
  end
end

module CrystalClick::WidePartWriter
  # Rewrite the fixture manifest after replacing serialization.json, preserving
  # the encoded/raw checksum distinction for compressed data lanes.
  def self.w218_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(
          name,
          bytes.size.to_u64,
          file_hash,
          true,
          raw.size.to_u64,
          CityHashV1.file_hash(raw),
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    PartChecksumsWriter.write(part, records)
    nil
  end
end

describe "W218 recursive Tuple serialization metadata" do
  it "reads an ordinary recursive part carrying the stock ordered Tuple subcolumns shape" do
    with_w218_part("direct") do |part|
      w218_write_direct_part(part)
      w218_attach_payload_info(part, w218_leaf_subcolumns)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_direct_schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      rows = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          {
            row.child_at(0).object_document.value_for("t").bytes[0],
            row.child_at(1).bulk_value.as_uint64,
          }
        end
      end
      rows.should eq([{3_u8, 30_u64}, {5_u8, 50_u64}, {7_u8, 70_u64}])

      selected = reader.read_marks(1, 1)
      selected.size.should eq(1)
      selected[0].map { |row| row.child_at(1).bulk_value.as_uint64 }.should eq([70_u64])
    end
  end

  it "accepts false and absent exact-default flags on root, key, and Tuple children" do
    with_w218_part("optional-exact-defaults") do |part|
      w218_write_direct_part(part)
      w218_attach_payload_info(
        part,
        [w218_scalar_info(exact: false), w218_scalar_info(exact: nil)] of JSON::Any,
        root_exact: false,
        key_exact: true,
      )

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_direct_schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      reader.read_marks(1, 1)[0].map do |row|
        row.child_at(0).object_document.value_for("t").bytes[0]
      end.should eq([7_u8])
    end

    with_w218_part("true-exact-defaults") do |part|
      w218_write_direct_part(part)
      w218_attach_payload_info(
        part,
        [w218_scalar_info, w218_scalar_info] of JSON::Any,
        root_exact: true,
        key_exact: true,
      )

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_direct_schema)
      reader.read_marks(1, 1)[0].map do |row|
        row.child_at(1).bulk_value.as_uint64
      end.should eq([70_u64])
    end
  end

  it "validates stock subcolumns for a JSON-free BinaryBulk Tuple child" do
    schema = w218_bulk_tuple_schema
    rows = [
      w218_bulk_tuple_row(schema, 13_u8, 130_u64, "a"),
      w218_bulk_tuple_row(schema, 23_u8, 230_u64, "b"),
      w218_bulk_tuple_row(schema, 33_u8, 330_u64, "c"),
    ] of CrystalClick::StorageColumnValue

    with_w218_part("bulk-tuple-child") do |part|
      w218_write_part(part, schema, rows)
      stats_info = w218_tuple_info(3_i64, w218_leaf_subcolumns)
      w218_attach_payload_info(part, [w218_scalar_info, stats_info] of JSON::Any)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      actual = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          stats = row.child_at(1).bulk_value
          {
            row.child_at(0).object_document.value_for("t").bytes[0],
            stats.child_at(0).as_uint64,
            stats.child_at(1).as_string,
          }
        end
      end
      actual.should eq([
        {13_u8, 130_u64, "a"},
        {23_u8, 230_u64, "b"},
        {33_u8, 330_u64, "c"},
      ])
    end

    with_w218_part("bulk-tuple-child-wrong-arity") do |part|
      w218_write_part(part, schema, rows)
      stats_info = w218_tuple_info(3_i64, [w218_scalar_info] of JSON::Any)
      w218_attach_payload_info(part, [w218_scalar_info, stats_info] of JSON::Any)
      w218_expect_rejected(part, schema)
    end
  end

  it "keeps a JSON-free BinaryBulk Array opaque between nested Tuple metadata nodes" do
    schema = w218_bulk_array_tuple_schema
    rows = [
      w218_bulk_array_tuple_row(schema, 11_u8, [{110_u64, 111_u64}] of {UInt64, UInt64}, 1_100_u64),
      w218_bulk_array_tuple_row(schema, 21_u8, [{210_u64, 211_u64}, {212_u64, 213_u64}] of {UInt64, UInt64}, 2_100_u64),
      w218_bulk_array_tuple_row(schema, 31_u8, [] of {UInt64, UInt64}, 3_100_u64),
    ] of CrystalClick::StorageColumnValue

    with_w218_part("bulk-array-tuple") do |part|
      w218_write_part(part, schema, rows)
      stats_info = w218_tuple_info(
        3_i64,
        [w218_scalar_info, w218_scalar_info] of JSON::Any,
      )
      w218_attach_payload_info(part, [w218_scalar_info, stats_info] of JSON::Any)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      actual = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          stats = row.child_at(1).bulk_value
          items = stats.child_at(0)
          document = row.child_at(0).object_document.value_for("t").bytes[0]
          tail = stats.child_at(1).as_uint64
          if items.element_count == 0
            {document, 0, 0_u64, 0_u64, tail}
          else
            first = items.element_at(0)
            {
              document,
              items.element_count,
              first.child_at(0).as_uint64,
              first.child_at(1).as_uint64,
              tail,
            }
          end
        end
      end
      actual.should eq([
        {11_u8, 1, 110_u64, 111_u64, 1_100_u64},
        {21_u8, 2, 210_u64, 211_u64, 2_100_u64},
        {31_u8, 0, 0_u64, 0_u64, 3_100_u64},
      ])
    end

    with_w218_part("bulk-array-tuple-forbidden-descendants") do |part|
      w218_write_part(part, schema, rows)
      array_info = w218_scalar_info(rows: 3_i64)
      array_info.as_h["subcolumns"] = JSON::Any.new([
        w218_tuple_info(3_i64, [w218_scalar_info, w218_scalar_info] of JSON::Any),
      ] of JSON::Any)
      stats_info = w218_tuple_info(
        3_i64,
        [array_info, w218_scalar_info] of JSON::Any,
      )
      w218_attach_payload_info(part, [w218_scalar_info, stats_info] of JSON::Any)
      w218_expect_rejected(part, schema)
    end
  end

  it "validates recursive subcolumns by Tuple arity and position, including nested Tuple row domains" do
    with_w218_part("nested") do |part|
      w218_write_nested_part(part)
      group_info = w218_tuple_info(3_i64, w218_leaf_subcolumns)
      w218_attach_payload_info(
        part,
        [group_info, w218_scalar_info] of JSON::Any,
      )

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_nested_schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      rows = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          group = row.child_at(0)
          {
            group.child_at(0).object_document.value_for("t").bytes[0],
            group.child_at(1).bulk_value.as_uint64,
            row.child_at(1).bulk_value.as_uint64,
          }
        end
      end
      rows.should eq([
        {9_u8, 90_u64, 900_u64},
        {19_u8, 190_u64, 1900_u64},
        {29_u8, 290_u64, 2900_u64},
      ])
    end
  end

  it "rejects child metadata moved to a different Tuple position" do
    with_w218_part("nested-wrong-position") do |part|
      w218_write_nested_part(part)
      group_info = w218_tuple_info(3_i64, w218_leaf_subcolumns)
      w218_attach_payload_info(
        part,
        [w218_scalar_info, group_info] of JSON::Any,
      )
      w218_expect_rejected(part, w218_nested_schema)
    end
  end

  it "preserves the legacy profile with no selected Tuple serialization entry" do
    with_w218_part("legacy-absence") do |part|
      w218_write_direct_part(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_direct_schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      reader.read_marks(1, 1)[0].map do |row|
        row.child_at(0).object_document.value_for("t").bytes[0]
      end.should eq([7_u8])
    end

    with_w218_part("legacy-selected-entry-no-subcolumns") do |part|
      w218_write_direct_part(part)
      w218_attach_payload_info(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", w218_direct_schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      reader.read_marks(1, 1)[0].map do |row|
        row.child_at(1).bulk_value.as_uint64
      end.should eq([70_u64])
    end
  end

  it "rejects malformed child arity, JSON field types, counts, kinds, fields, order, and off-schema depth" do
    wrong_rows = w218_scalar_info
    wrong_rows.as_h["num_rows"] = JSON::Any.new("3")

    wrong_kind = w218_scalar_info
    wrong_kind.as_h["kind"] = JSON::Any.new("Sparse")

    wrong_exact_flag = w218_scalar_info
    wrong_exact_flag.as_h["exact_num_defaults"] = JSON::Any.new(1_i64)

    too_many_defaults = w218_scalar_info(defaults: 4_i64)
    negative_defaults = w218_scalar_info(defaults: -1_i64)
    wrong_domain = w218_scalar_info(rows: 2_i64)

    extra_field = w218_scalar_info
    extra_field.as_h["name"] = JSON::Any.new("doc")

    deep_off_schema = w218_scalar_info
    40.times do
      deep_off_schema = w218_tuple_info(3_i64, [deep_off_schema] of JSON::Any)
    end

    malformed_cases = [
      {"short-arity", [w218_scalar_info] of JSON::Any},
      {"wrong-json-type", [wrong_rows, w218_scalar_info] of JSON::Any},
      {"wrong-kind", [wrong_kind, w218_scalar_info] of JSON::Any},
      {"wrong-exact-flag-type", [wrong_exact_flag, w218_scalar_info] of JSON::Any},
      {"defaults-exceed-rows", [too_many_defaults, w218_scalar_info] of JSON::Any},
      {"negative-defaults", [negative_defaults, w218_scalar_info] of JSON::Any},
      {"tuple-row-domain", [wrong_domain, w218_scalar_info] of JSON::Any},
      {"child-extra-field", [extra_field, w218_scalar_info] of JSON::Any},
      {"wrong-position-compound-vs-leaf", [w218_scalar_info, w218_tuple_info(3_i64, w218_leaf_subcolumns)] of JSON::Any},
      {"deep-off-schema-under-leaf", [w218_scalar_info, deep_off_schema] of JSON::Any},
    ] of Tuple(String, Array(JSON::Any))

    malformed_cases.each do |label, subcolumns|
      with_w218_part(label) do |part|
        w218_write_direct_part(part)
        w218_attach_payload_info(part, subcolumns)
        w218_expect_rejected(part)
      end
    end
  end

  it "rejects Array descendant subcolumns rather than confusing occurrence rows with Tuple rows" do
    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(items Array(Tuple(doc JSON(t UInt8), inner UInt64)), tail UInt64)"
    )
    plan = w218_object_plan(w218_json_schema)
    object_plans = {"root/tuple[0]/array[0]/tuple[0]" => plan}
    empty = [] of CrystalClick::StorageColumnValue
    item = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(w218_document(41_u8)),
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(410_u64)),
    ] of CrystalClick::StorageColumnValue)
    rows = [
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.array([item] of CrystalClick::StorageColumnValue),
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(900_u64)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.array(empty),
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(901_u64)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.array(empty),
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(902_u64)),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue

    with_w218_part("array-occurrence-domain") do |part|
      granules = [
        [rows[0], rows[1]] of CrystalClick::StorageColumnValue,
        [rows[2]] of CrystalClick::StorageColumnValue,
      ] of Array(CrystalClick::StorageColumnValue)
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[101_u64, 202_u64, 303_u64],
        "payload",
        schema,
        object_plans,
        granules,
        rows_per_mark: 2,
      )

      # ClickHouse's Array wrapper carries a row-domain serializer entry; the
      # recursive element occurrence schedule is owned by the Array size lane.
      w218_attach_payload_info(
        part,
        [w218_scalar_info(rows: 3_i64), w218_scalar_info(rows: 3_i64)] of JSON::Any,
      )
      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      values = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          row.child_at(0).array_values.map do |item|
            item.child_at(0).object_document.value_for("t").bytes[0]
          end
        end
      end
      values.should eq([[41_u8], [] of UInt8, [] of UInt8])
    end

    with_w218_part("array-descendant-subcolumns") do |part|
      granules = [
        [rows[0], rows[1]] of CrystalClick::StorageColumnValue,
        [rows[2]] of CrystalClick::StorageColumnValue,
      ] of Array(CrystalClick::StorageColumnValue)
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[101_u64, 202_u64, 303_u64],
        "payload",
        schema,
        object_plans,
        granules,
        rows_per_mark: 2,
      )

      array_info = w218_scalar_info(rows: 3_i64)
      array_info.as_h["subcolumns"] = JSON::Any.new([
        w218_tuple_info(3_i64, w218_leaf_subcolumns),
      ] of JSON::Any)
      w218_attach_payload_info(part, [array_info, w218_scalar_info(rows: 3_i64)] of JSON::Any)
      w218_expect_rejected(part, schema)
    end
  end

  it "keeps root Array Default metadata valid and rejects forged Tuple descendants" do
    schema = w218_root_array_schema

    with_w218_part("root-array-default") do |part|
      w218_write_part(part, schema, w218_root_array_rows)
      w218_attach_payload_info(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      values = reader.read_marks(0, 2).flat_map do |mark|
        mark.map do |row|
          row.array_values.map do |item|
            {
              item.child_at(0).object_document.value_for("t").bytes[0],
              item.child_at(1).bulk_value.as_uint64,
            }
          end
        end
      end
      values.should eq([
        [{41_u8, 410_u64}] of Tuple(UInt8, UInt64),
        [] of Tuple(UInt8, UInt64),
        [] of Tuple(UInt8, UInt64),
      ])
    end

    with_w218_part("root-array-forged-subcolumns") do |part|
      w218_write_part(part, schema, w218_root_array_rows)
      w218_attach_payload_info(
        part,
        [w218_tuple_info(3_i64, w218_leaf_subcolumns)] of JSON::Any,
      )
      w218_expect_rejected(part, schema)
    end
  end

  it "preflights metadata depth, node, and element budgets against a valid Tuple shape" do
    subcolumns = w218_leaf_subcolumns
    default_limits = CrystalClick::BinaryCodecLimits.default

    exact_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 3,
      max_elements: 2,
      max_bytes: 1_024,
    )
    CrystalClick::RecursiveTupleSerializationMetadata.validate_subcolumns!(
      subcolumns, w218_direct_schema, 3_u64, exact_limits
    )

    shallow_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 1,
      max_nodes: default_limits.max_nodes,
      max_elements: default_limits.max_elements,
      max_bytes: default_limits.max_bytes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::RecursiveTupleSerializationMetadata.validate_subcolumns!(
        subcolumns, w218_direct_schema, 3_u64, shallow_limits
      )
    end

    short_node_budget = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 2,
      max_elements: default_limits.max_elements,
      max_bytes: default_limits.max_bytes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::RecursiveTupleSerializationMetadata.validate_subcolumns!(
        subcolumns, w218_direct_schema, 3_u64, short_node_budget
      )
    end

    short_element_budget = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: default_limits.max_nodes,
      max_elements: 1,
      max_bytes: default_limits.max_bytes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::RecursiveTupleSerializationMetadata.validate_subcolumns!(
        subcolumns, w218_direct_schema, 3_u64, short_element_budget
      )
    end
  end
end
