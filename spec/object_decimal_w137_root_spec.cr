require "./spec_helper"

private def w137_root_types(
  d32_precision : Int32 = 9,
  d32_scale : Int32 = 2,
) : Hash(String, CrystalClick::BinaryDataType)
  {
    "d32"  => CrystalClick::BinaryDataType.decimal(32, d32_precision, d32_scale),
    "d64"  => CrystalClick::BinaryDataType.decimal(64, 18, 4),
    "d128" => CrystalClick::BinaryDataType.decimal(128, 38, 10),
    "d256" => CrystalClick::BinaryDataType.decimal(256, 76, 38),
  }
end

private def w137_root_schema(
  types : Hash(String, CrystalClick::BinaryDataType) = w137_root_types,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(types, max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w137_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w137_root_decimal_bytes(width : Int32, row : Int32) : Bytes
  Bytes.new(width) do |index|
    ((row * 53 + index * 29 + width) & 0xff).to_u8
  end
end

private def w137_root_join_bytes(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }
  joined = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      joined[offset] = byte
      offset += 1
    end
  end
  joined
end

private def w137_root_documents(schema : CrystalClick::ObjectDocumentSchema) : Array(CrystalClick::ObjectDocument)
  Array(CrystalClick::ObjectDocument).new(4) do |row|
    values = Hash(String, CrystalClick::BinaryValue).new(initial_capacity: schema.typed_paths.size)
    schema.typed_paths.each do |path, type|
      values[path] = CrystalClick::BinaryValue.fixed(type, w137_root_decimal_bytes(type.fixed_width.not_nil!, row))
    end
    CrystalClick::ObjectDocument.new(values)
  end
end

private def w137_root_granules(schema : CrystalClick::ObjectDocumentSchema) : Array(Array(CrystalClick::ObjectDocument))
  documents = w137_root_documents(schema)
  [documents[0, 2], documents[2, 2]] of Array(CrystalClick::ObjectDocument)
end

private def w137_root_assert_document(
  actual : CrystalClick::ObjectDocument,
  schema : CrystalClick::ObjectDocumentSchema,
  row : Int32,
) : Nil
  types = schema.typed_paths
  actual.paths.should eq(types.keys.sort)
  types.each do |path, type|
    value = actual.value_for(path)
    value.type.should eq(type)
    value.bytes.should eq(w137_root_decimal_bytes(type.fixed_width.not_nil!, row))
  end
  nil
end

private def w137_root_assert_marks(
  actual : Array(Array(CrystalClick::ObjectDocument)),
  schema : CrystalClick::ObjectDocumentSchema,
  first_row : Int32,
  expected_mark_count : Int32,
) : Nil
  actual.size.should eq(expected_mark_count)
  row = first_row
  actual.each do |mark|
    mark.size.should eq(2)
    mark.each do |document|
      w137_root_assert_document(document, schema, row)
      row += 1
    end
  end
  nil
end

private def with_w137_root(&)
  root = File.tempname("crystal-click-w137-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w137_root_write(
  path : String,
  schema : CrystalClick::ObjectDocumentSchema,
  granules : Array(Array(CrystalClick::ObjectDocument)) = w137_root_granules(schema),
  keys : Slice(UInt64) = Slice[0_u64, 2_u64, 8_u64, 10_u64],
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    keys,
    "payload",
    schema,
    w137_root_plan(schema),
    granules,
    rows_per_mark: 2,
    frame_bytes: 1024,
  )
end

private def w137_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1370000-0000-4000-8000-000000000137"
  table_uuid = "b1370000-0000-4000-8000-000000000137"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

describe "W137 declared Decimal Object consumers" do
  it "preserves exact raw coefficients through all Decimal widths and file/column windows" do
    schema = w137_root_schema
    plan = w137_root_plan(schema)
    granules = w137_root_granules(schema)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, granules)
    streams.mark_count.should eq(2)

    schema.typed_paths.each do |path, type|
      width = type.fixed_width.not_nil!
      stream = streams.typed_for(path).stream("root.data")
      expected = Bytes.new(width * 4) do |index|
        row = index // width
        byte_index = index % width
        w137_root_decimal_bytes(width, row)[byte_index]
      end
      stream.bytes.should eq(expected)
      stream.offsets.should eq([0_u64, (width * 2).to_u64, (width * 4).to_u64])
    end

    w137_root_assert_marks(CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams), schema, 0, 2)
    w137_root_assert_marks(
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 1, mark_count: 1),
      schema,
      2,
      1,
    )
    CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 2, mark_count: 0).should be_empty

    with_w137_root do |root|
      part = w137_root_write(File.join(root, "all_1_1_0"), schema, granules)
      file_rows = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      w137_root_assert_marks(file_rows, schema, 0, 2)
      file_middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      w137_root_assert_marks(file_middle, schema, 2, 1)
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 2, mark_count: 0, hashed: true
      ).should be_empty

      column = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      column.row_count.should eq(4_u64)
      w137_root_assert_marks(column.read_marks(0, 2), schema, 0, 2)
      w137_root_assert_marks(column.read_marks(1, 1), schema, 2, 1)
      column.read_marks(2, 0).should be_empty
    end
  end

  it "materializes owned catalog values and serves table windows and UInt64 key candidates" do
    schema = w137_root_schema
    with_w137_root do |root|
      table_path = w137_root_catalog(root, schema.declaration)
      w137_root_write(File.join(table_path, "all_1_1_0"), schema)
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      selected = catalog_table["payload"]
      documents = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      documents.size.should eq(4)
      documents.each_with_index { |document, row| w137_root_assert_document(document, schema, row) }

      documents[1].paths.clear
      detached = documents[1].value_for("d128").bytes
      detached[0] ^= 0xff_u8
      w137_root_assert_document(documents[1], schema, 1)
      reread = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      reread.each_with_index { |document, row| w137_root_assert_document(document, schema, row) }

      window_keys = [] of UInt64
      window_documents = [] of CrystalClick::ObjectDocument
      catalog_table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        window_keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| window_documents << document }
        nil
      end
      window_keys.should eq([2_u64, 8_u64])
      window_documents.size.should eq(2)
      w137_root_assert_document(window_documents[0], schema, 1)
      w137_root_assert_document(window_documents[1], schema, 2)

      callbacks = 0
      catalog_table.scan_typed_window(["payload", "pk"], 4_u64, 1) { |_batch| callbacks += 1; nil }
      callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        catalog_table.scan_typed_window(["payload", "pk"], 4_u64, 0) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)

      candidate_keys = [] of UInt64
      residual_coefficients = [] of Tuple(UInt64, Bytes)
      catalog_table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 2_u64, upper_bound: 8_u64) do |batch|
        batch_keys = batch.values_for("pk")
        batch_documents = batch.object_documents_for("payload")
        batch_documents.size.should eq(batch_keys.size)
        candidate_keys.concat(batch_keys)
        batch_keys.each_with_index do |key, index|
          next unless 2_u64 <= key <= 8_u64
          residual_coefficients << {key, batch_documents[index].value_for("d256").bytes}
        end
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      residual_coefficients.should eq([
        {2_u64, w137_root_decimal_bytes(32, 1)},
        {8_u64, w137_root_decimal_bytes(32, 2)},
      ])
    end
  end

  it "refuses publication on nominal mismatch and stops on later-part Decimal P/S drift before callbacks" do
    schema = w137_root_schema
    with_w137_root do |root|
      target = File.join(root, "rejected_1_1_0")
      granules = w137_root_granules(schema)
      original = granules[0][0]
      changed = Hash(String, CrystalClick::BinaryValue).new(initial_capacity: original.paths.size)
      original.paths.each do |path|
        value = original.value_for(path)
        changed[path] = if path == "d32"
                          CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int32"), value.bytes)
                        else
                          value
                        end
      end
      granules[0][0] = CrystalClick::ObjectDocument.new(changed)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w137_root_write(target, schema, granules)
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w137_root do |root|
      first_schema = w137_root_schema
      first = w137_root_write(File.join(root, "all_1_1_0"), first_schema, keys: Slice[0_u64, 2_u64, 8_u64, 10_u64])

      # The second part is independently valid, but its unselected candidate
      # marks cannot hide a declared Decimal precision/scale drift.
      later_schema = w137_root_schema(w137_root_types(8, 1))
      later = w137_root_write(File.join(root, "all_2_2_0"), later_schema, keys: Slice[20_u64, 22_u64, 28_u64, 30_u64])
      File.read(File.join(later, "columns.txt")).should contain("d32 Decimal(8, 1)")
      CrystalClick::ObjectColumnReader.open(later, "payload", later_schema).row_count.should eq(4_u64)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first, later], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects malformed Decimal metadata in a selected physical Object part" do
    schema = w137_root_schema
    with_w137_root do |root|
      part = w137_root_write(File.join(root, "all_1_1_0"), schema)
      columns_path = File.join(part, "columns.txt")
      malformed = schema.declaration.sub("d32 Decimal(9, 2)", "d32 Decimal(09, 2)")
      File.write(columns_path, File.read(columns_path).gsub(schema.declaration, malformed))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      end
    end
  end
end
