require "./spec_helper"

private def w132_root_schema : CrystalClick::ObjectDocumentSchema
  types = {
    "b"    => CrystalClick::BinaryDataType.primitive("Bool"),
    "f32"  => CrystalClick::BinaryDataType.primitive("Float32"),
    "f64"  => CrystalClick::BinaryDataType.primitive("Float64"),
    "i128" => CrystalClick::BinaryDataType.primitive("Int128"),
    "i16"  => CrystalClick::BinaryDataType.primitive("Int16"),
    "i256" => CrystalClick::BinaryDataType.primitive("Int256"),
    "i32"  => CrystalClick::BinaryDataType.primitive("Int32"),
    "i64"  => CrystalClick::BinaryDataType.primitive("Int64"),
    "i8"   => CrystalClick::BinaryDataType.primitive("Int8"),
    "s"    => CrystalClick::BinaryDataType.primitive("String"),
    "u128" => CrystalClick::BinaryDataType.primitive("UInt128"),
    "u16"  => CrystalClick::BinaryDataType.primitive("UInt16"),
    "u256" => CrystalClick::BinaryDataType.primitive("UInt256"),
    "u32"  => CrystalClick::BinaryDataType.primitive("UInt32"),
    "u64"  => CrystalClick::BinaryDataType.primitive("UInt64"),
    "u8"   => CrystalClick::BinaryDataType.primitive("UInt8"),
  }
  CrystalClick::ObjectDocumentSchema.new(types, max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w132_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w132_root_integer_bytes(width : Int32, row : Int32, signed : Bool) : Bytes
  upper = row.odd?
  if signed
    fill = upper ? 0xff_u8 : 0x00_u8
    final = upper ? 0x7f_u8 : 0x80_u8
    Bytes.new(width) { |index| index == width - 1 ? final : fill }
  else
    fill = upper ? 0xff_u8 : 0x00_u8
    Bytes.new(width) { |_index| fill }
  end
end

private def w132_root_numeric_bytes(path : String, row : Int32) : Bytes
  case path
  when "f32"
    case row
    when 0 then Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8] # +0
    when 1 then Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8] # -0
    when 2 then Bytes[0x45_u8, 0x23_u8, 0xc1_u8, 0x7f_u8] # quiet NaN with payload
    else        Bytes[0x00_u8, 0x00_u8, 0x80_u8, 0x7f_u8] # +infinity
    end
  when "f64"
    case row
    when 0 then Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8] # +0
    when 1 then Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8] # -0
    when 2 then Bytes[0xbc_u8, 0x9a_u8, 0x78_u8, 0x56_u8, 0x34_u8, 0x12_u8, 0xf8_u8, 0x7f_u8] # quiet NaN with payload
    else        Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf0_u8, 0xff_u8] # -infinity
    end
  when "i8"   then w132_root_integer_bytes(1, row, true)
  when "u8"   then w132_root_integer_bytes(1, row, false)
  when "i16"  then w132_root_integer_bytes(2, row, true)
  when "u16"  then w132_root_integer_bytes(2, row, false)
  when "i32"  then w132_root_integer_bytes(4, row, true)
  when "u32"  then w132_root_integer_bytes(4, row, false)
  when "i64"  then w132_root_integer_bytes(8, row, true)
  when "u64"  then w132_root_integer_bytes(8, row, false)
  when "i128" then w132_root_integer_bytes(16, row, true)
  when "u128" then w132_root_integer_bytes(16, row, false)
  when "i256" then w132_root_integer_bytes(32, row, true)
  when "u256" then w132_root_integer_bytes(32, row, false)
  else             raise ArgumentError.new("unknown W132 numeric test path")
  end
end

private def w132_root_documents(schema : CrystalClick::ObjectDocumentSchema) : Array(CrystalClick::ObjectDocument)
  Array(CrystalClick::ObjectDocument).new(4) do |row|
    fields = {} of String => CrystalClick::BinaryValue
    schema.typed_paths.each do |path, type|
      value = case path
              when "b"
                CrystalClick::BinaryValue.bool(row.even?)
              when "s"
                CrystalClick::BinaryValue.string("row#{row}\0é")
              else
                CrystalClick::BinaryValue.fixed(type, w132_root_numeric_bytes(path, row))
              end
      fields[path] = value
    end
    CrystalClick::ObjectDocument.new(fields)
  end
end

private def w132_root_granules(schema : CrystalClick::ObjectDocumentSchema) : Array(Array(CrystalClick::ObjectDocument))
  documents = w132_root_documents(schema)
  [documents[0, 2], documents[2, 2]]
end

private def w132_root_write(
  destination : String,
  schema : CrystalClick::ObjectDocumentSchema,
  granules : Array(Array(CrystalClick::ObjectDocument)) = w132_root_granules(schema),
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    destination,
    "pk",
    Slice[10_u64, 20_u64, 30_u64, 40_u64],
    "payload",
    schema,
    w132_root_plan(schema),
    granules,
    rows_per_mark: 2,
    frame_bytes: 1024,
  )
end

private def w132_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1320000-0000-4000-8000-000000000132"
  table_uuid = "b1320000-0000-4000-8000-000000000132"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

private def with_w132_root(&)
  root = File.tempname("crystal-click-w132-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w132_root_assert_document(document : CrystalClick::ObjectDocument, row : Int32) : Nil
  {
    "i8" => "Int8", "i16" => "Int16", "i32" => "Int32", "i64" => "Int64",
    "i128" => "Int128", "i256" => "Int256", "u8" => "UInt8", "u16" => "UInt16",
    "u32" => "UInt32", "u64" => "UInt64", "u128" => "UInt128", "u256" => "UInt256",
    "f32" => "Float32", "f64" => "Float64", "b" => "Bool", "s" => "String",
  }.each do |path, type_name|
    value = document.value_for(path)
    value.type.should eq(CrystalClick::BinaryDataType.primitive(type_name))
    expected = case path
               when "b" then Bytes[row.even? ? 1_u8 : 0_u8]
               when "s" then "row#{row}\0é".to_slice
               else          w132_root_numeric_bytes(path, row)
               end
    value.bytes.should eq(expected)
  end
  expect_raises(ArgumentError) { document.value_for("u8").as_bool }
  expect_raises(ArgumentError) { document.value_for("b").as_uint64 }
  document.value_for("i64").as_int64.should eq(row.odd? ? Int64::MAX : Int64::MIN)
  document.value_for("u64").as_uint64.should eq(row.odd? ? UInt64::MAX : 0_u64)
end

describe "W132 broad numeric Object consumer contract" do
  it "decodes nonzero Object Bool bytes as true and re-encodes the canonical byte" do
    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    structure = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structure, {"b" => bool_type})
    documents = Array(CrystalClick::ObjectDocument).new(3) do
      CrystalClick::ObjectDocument.new({"b" => CrystalClick::BinaryValue.bool(false)})
    end
    baseline = CrystalClick::ObjectDocumentCodec.encode(plan, [documents])
    bool_lane = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[0x02_u8, 0x80_u8, 0xff_u8], [0_u64, 3_u64]),
    })
    streams = CrystalClick::ObjectDocumentStreams.new(
      baseline.structures,
      baseline.rows_per_mark,
      {"b" => bool_lane},
      {} of String => CrystalClick::DynamicValueStreams,
      baseline.shared,
    )

    decoded = CrystalClick::ObjectDocumentCodec.decode({"b" => bool_type}, streams)
    decoded[0].map { |document| document.value_for("b").as_bool }.should eq([true, true, true])
    canonical = CrystalClick::ObjectDocumentCodec.encode(plan, decoded)
    canonical.typed_for("b").stream("root.data").bytes.should eq(Bytes[0x01_u8, 0x01_u8, 0x01_u8])
  end

  it "preserves independently specified numeric bytes through whole-part and file-column reads" do
    with_w132_root do |root|
      schema = w132_root_schema
      part = w132_root_write(File.join(root, "all_1_1_0"), schema)
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      actual = reader.read_marks(0, 2).flatten
      actual.size.should eq(4)
      actual.each_with_index { |document, row| w132_root_assert_document(document, row) }

      middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      middle.flatten.each_with_index { |document, index| w132_root_assert_document(document, index + 2) }
      reader.read_marks(2, 0).should be_empty
    end
  end

  it "keeps scalar identities and retained documents across catalog, windows, zero ranges, and PK candidates" do
    with_w132_root do |root|
      schema = w132_root_schema
      directory = w132_root_catalog(root, schema.declaration)
      part = w132_root_write(File.join(directory, "all_1_1_0"), schema)
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]

      catalog_values = table["payload"].values.map(&.as(CrystalClick::ObjectDocument))
      catalog_values.each_with_index { |document, row| w132_root_assert_document(document, row) }

      window = [] of Tuple(UInt64, Bytes, Bytes)
      retained = [] of CrystalClick::ObjectDocument
      table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        batch.column_type_for("payload").should eq(schema.declaration)
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        keys.each_with_index do |key, index|
          document = documents[index]
          row = key == 20_u64 ? 1 : 2
          window << {key, document.value_for("i64").bytes, document.value_for("u64").bytes}
          retained << document
          w132_root_assert_document(document, row)
        end
        nil
      end
      window.should eq([
        {20_u64, w132_root_numeric_bytes("i64", 1), w132_root_numeric_bytes("u64", 1)},
        {30_u64, w132_root_numeric_bytes("i64", 2), w132_root_numeric_bytes("u64", 2)},
      ])
      retained.size.should eq(2)
      retained.each_with_index { |document, index| w132_root_assert_document(document, index + 1) }

      raw_snapshot = retained[0].value_for("i256").bytes
      raw_snapshot[0] ^= 0xff_u8
      retained[0].value_for("i256").bytes.should eq(w132_root_numeric_bytes("i256", 1))
      reread = table["payload"].values[1].as(CrystalClick::ObjectDocument)
      w132_root_assert_document(reread, 1)

      physical_table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload", "pk"])
      zero_callbacks = 0
      physical_table.scan_typed_window(4_u64, 1) { |_batch| zero_callbacks += 1; nil }
      zero_callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        physical_table.scan_typed_window(4_u64, 0) { |_batch| zero_callbacks += 1; nil }
      end
      zero_callbacks.should eq(0)

      candidates = [] of UInt64
      residual = [] of Tuple(UInt64, Int64, UInt64)
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 20_u64, upper_bound: 30_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        candidates.concat(keys)
        keys.each_with_index do |key, index|
          next unless 20_u64 <= key <= 30_u64
          residual << {key, documents[index].value_for("i64").as_int64, documents[index].value_for("u64").as_uint64}
        end
        nil
      end
      candidates.should eq([10_u64, 20_u64, 30_u64, 40_u64])
      residual.should eq([
        {20_u64, Int64::MAX, UInt64::MAX},
        {30_u64, Int64::MIN, 0_u64},
      ])
    end
  end

  it "rejects Bool bytes supplied as UInt8 and stops on later-part nominal schema drift before callbacks" do
    with_w132_root do |root|
      schema = w132_root_schema
      granules = w132_root_granules(schema)
      first = granules[0][0]
      changed = {} of String => CrystalClick::BinaryValue
      first.paths.each do |path|
        changed[path] = path == "u8" ? CrystalClick::BinaryValue.bool(true) : first.value_for(path)
      end
      granules[0][0] = CrystalClick::ObjectDocument.new(changed)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w132_root_write(File.join(root, "rejected_1_1_0"), schema, granules)
      end
      Dir.children(root).should be_empty

      granules = w132_root_granules(schema)
      first_part = w132_root_write(File.join(root, "all_1_1_0"), schema, granules)
      later_part = w132_root_write(File.join(root, "all_2_2_0"), schema, granules)
      columns = File.join(later_part, "columns.txt")
      File.write(columns, File.read(columns).sub("i8 Int8", "i8 UInt8"))

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first_part, later_part], ["payload", "pk"])
        table.scan_typed { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end
end
