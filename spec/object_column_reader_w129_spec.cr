require "./spec_helper"

private def w129_column_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt64")},
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
  )
end

private def w129_column_plan : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]),
      {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])},
    ),
    w129_column_schema.typed_paths,
  )
end

private def w129_column_documents : Array(Array(CrystalClick::ObjectDocument))
  [
    [
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(4_u64),
        "d" => CrystalClick::BinaryValue.string("a\0b"),
      }),
      CrystalClick::ObjectDocument.new({
        "t"        => CrystalClick::BinaryValue.uint64(5_u64),
        "shared.x" => CrystalClick::BinaryValue.bool(true),
      }),
    ],
    [
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(6_u64),
        "d" => CrystalClick::BinaryValue.int64(-7_i64),
      }),
    ],
  ]
end

private def w129_column_write(path : String, profile = CrystalClick::BinaryBulkProfile.with_size_stream) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    Slice[1_u64, 1_u64, 9_u64],
    "payload",
    w129_column_schema,
    w129_column_plan,
    w129_column_documents,
    rows_per_mark: 2,
    frame_bytes: 16,
    profile: profile,
  )
end

private def with_w129_column_part(&)
  parent = File.tempname("crystal-click-w129-object-column-")
  Dir.mkdir(parent)
  begin
    part = w129_column_write(File.join(parent, "all_1_1_0"))
    yield parent, part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w129_column_file(part : String, logical_name : String, extension : String) : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

describe "W129 normalized Object column reader" do
  it "inspects all grids into detached metadata and discovers independent String profiles" do
    with_w129_column_part do |_parent, part|
      descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
        part,
        "payload",
        w129_column_schema.typed_paths,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        hashed: true,
      )
      descriptor.row_count.should eq(3_u64)
      descriptor.mark_row_counts.should eq([2_u64, 1_u64])
      descriptor.logical_read_bytes.should be > 0_u64

      exposed_rows = descriptor.mark_row_counts
      exposed_rows[0] = 99_u64
      descriptor.mark_row_counts.should eq([2_u64, 1_u64])

      descriptor.physical_stream_names.includes?("payload.t").should be_true
      descriptor.selected_checksum_names.includes?(File.basename(w129_column_file(part, "payload.t", "bin"))).should be_true

      serializers = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h["columns"].as_a
      serializer_names = serializers.map { |entry| entry.as_h["name"].as_s }
      serializer_names.includes?("pk").should be_true
      # An omitted column serializer has ClickHouse's implicit Default kind.
      serializer_names.includes?("payload").should be_false

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_column_schema)
      reader.row_count.should eq(3_u64)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      reader.logical_read_bytes.should eq(descriptor.logical_read_bytes)
      reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.with_size_stream)
      reader.schema_declaration.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt64)")
      reader.source_declaration.should eq(reader.schema_declaration)

      detached_names = reader.physical_stream_names
      detached_names[0] = "caller mutation"
      reader.physical_stream_names.includes?("caller mutation").should be_false

      selected = reader.read_marks(1, 1)
      selected.size.should eq(1)
      selected[0].size.should eq(1)
      selected[0][0].value_for("t").as_uint64.should eq(6_u64)
      selected[0][0].value_for("d").as_int64.should eq(-7_i64)
      reader.read_marks(2, 0).should be_empty
    end
  end

  it "does not decode selected payloads during inspection or validate unrelated key payloads" do
    with_w129_column_part do |_parent, part|
      payload_path = w129_column_file(part, "payload.t", "bin")
      payload = writable_file_bytes(payload_path)
      payload[0] = payload[0] ^ 0xff_u8
      File.open(payload_path, "wb") { |io| io.write(payload) }

      # The independent inspector and metadata owner only use checksummed
      # sizes and all-lane mark grids. They do not decode the damaged value.
      CrystalClick::ObjectDocumentFileReader.inspect(
        part,
        "payload",
        w129_column_schema.typed_paths,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        hashed: true,
      )
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_column_schema)
      expect_raises(CrystalClick::Error) { reader.read_marks(0, 1) }

      # The catalog's key lane is not an Object document value lane.
      clean_part = File.join(_parent, "clean_key_1_1_0")
      w129_column_write(clean_part)
      clean_key = w129_column_file(clean_part, "pk", "bin")
      clean_bytes = writable_file_bytes(clean_key)
      clean_bytes[0] = clean_bytes[0] ^ 0xff_u8
      File.open(clean_key, "wb") { |io| io.write(clean_bytes) }
      CrystalClick::ObjectColumnReader.open(clean_part, "payload", w129_column_schema).read_marks(0, 1).size.should eq(1)
    end
  end

  it "accepts an approximate explicit Default serializer count" do
    parent = File.tempname("crystal-click-w129-object-column-approximate-")
    Dir.mkdir(parent)
    begin
      documents = [] of CrystalClick::ObjectDocument
      10.times do |index|
        documents << CrystalClick::ObjectDocument.new({
          "t" => CrystalClick::BinaryValue.uint64(index.to_u64),
          "d" => CrystalClick::BinaryValue.string("value"),
        })
      end
      part = CrystalClick::WidePartWriter.write_uint64_object_pair(
        File.join(parent, "approximate_1_1_0"),
        "pk",
        Slice[0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64],
        "payload",
        w129_column_schema,
        w129_column_plan,
        [documents],
        rows_per_mark: 10,
        frame_bytes: 16,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      )

      serialization_path = File.join(part, "serialization.json")
      original = File.read(serialization_path)
      approximate = original
        .gsub("\"exact_num_defaults\":true", "\"exact_num_defaults\":false")
        .gsub("\"num_defaults\":10,", "\"num_defaults\":9,")
      approximate.includes?("\"exact_num_defaults\":false").should be_true
      approximate.includes?("\"num_defaults\":9,").should be_true
      # Keep the checksummed file size unchanged so this isolates serializer semantics.
      approximate.bytesize.should eq(original.bytesize)
      File.write(serialization_path, approximate)

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_column_schema)
      reader.read_marks(0, 1)[0].size.should eq(10)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "checks the selected roster, row count, serializer profile, and all grids for empty windows" do
    with_w129_column_part do |_parent, part|
      substreams_path = File.join(part, "columns_substreams.txt")
      substreams = File.read(substreams_path)
      File.write(substreams_path, substreams.gsub("\tpayload.t\n", ""))
      expect_raises(CrystalClick::Error) { CrystalClick::ObjectColumnReader.open(part, "payload", w129_column_schema) }

      recreated_part = File.join(_parent, "recreated_1_1_0")
      w129_column_write(recreated_part)
      File.write(File.join(recreated_part, "count.txt"), "4")
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::ObjectColumnReader.open(recreated_part, "payload", w129_column_schema) }

      mismatched_schema = CrystalClick::ObjectDocumentSchema.new(
        {"t" => CrystalClick::BinaryDataType.primitive("String")},
        max_dynamic_paths: 1,
        max_dynamic_types: 1,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectColumnReader.open(part, "payload", mismatched_schema)
      end

      profile_part = File.join(_parent, "profile_1_1_0")
      w129_column_write(profile_part)
      serialization_path = File.join(profile_part, "serialization.json")
      original_serialization = File.read(serialization_path)
      original_serialization.includes?("\"string\":1}").should be_true
      unsupported_serialization = original_serialization.gsub("\"string\":1}", "\"string\":2}")
      unsupported_serialization.includes?("\"string\":2}").should be_true
      unsupported_serialization.bytesize.should eq(original_serialization.bytesize)
      File.write(serialization_path, unsupported_serialization)
      expect_raises(CrystalClick::Error) { CrystalClick::ObjectColumnReader.open(profile_part, "payload", w129_column_schema) }

      grid_part = File.join(_parent, "grid_1_1_0")
      w129_column_write(grid_part)
      reader = CrystalClick::ObjectColumnReader.open(grid_part, "payload", w129_column_schema)
      File.delete(w129_column_file(grid_part, "payload.t", "mrk2"))
      expect_raises(CrystalClick::CorruptPartError) { reader.read_marks(1, 0) }
    end
  end
end
