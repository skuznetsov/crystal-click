require "./spec_helper"

private alias W146ObjectSignature = String

private def w146_consumer_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  low_string = CrystalClick::BinaryDataType.low_cardinality(string)
  low_nullable = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.nullable(string))
  CrystalClick::BinaryDataType.tuple(
    [
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.array(low_string)),
      low_nullable,
      string,
    ] of CrystalClick::BinaryDataType,
    ["items", "maybe", "note"] of String,
  )
end

private def w146_consumer_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new({"payload" => w146_consumer_type})
end

private def w146_consumer_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w146_consumer_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
    max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
    max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
    max_bytes: max_bytes,
  )
end

private def w146_assert_codec_byte_boundary(
  schema : CrystalClick::ObjectDocumentSchema,
  streams : CrystalClick::ObjectDocumentStreams,
  first_mark : Int,
  mark_count : Int,
) : Nil
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  decoded = CrystalClick::ObjectDocumentCodec.decode_with_budget(
    schema.typed_paths,
    streams,
    measured,
    first_mark,
    mark_count,
  )
  decoded.size.should eq(mark_count)

  exact = w146_consumer_limits(measured.wire_byte_count.to_i)
  CrystalClick::ObjectDocumentCodec.decode(
    schema.typed_paths,
    streams,
    first_mark: first_mark,
    mark_count: mark_count,
    limits: exact,
  ).size.should eq(mark_count)

  expect_raises(CrystalClick::CorruptPartError) do
    CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      first_mark: first_mark,
      mark_count: mark_count,
      limits: w146_consumer_limits(measured.wire_byte_count.to_i - 1),
    )
  end
  nil
end

private def w146_assert_file_reader_byte_boundary(
  part_path : String,
  schema : CrystalClick::ObjectDocumentSchema,
  first_mark : Int,
  mark_count : Int,
) : Nil
  read_with_limit = ->(max_bytes : Int32) do
    CrystalClick::ObjectDocumentFileReader.read(
      part_path,
      "payload",
      schema.typed_paths,
      first_mark,
      mark_count,
      hashed: true,
      limits: w146_consumer_limits(max_bytes),
    )
  end

  descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
    part_path, "payload", schema.typed_paths, hashed: true
  )
  name_floor = 0
  descriptor.physical_stream_names.each do |logical_name|
    name_floor = Math.max(name_floor, logical_name.bytesize + ".mrk2".bytesize)
    hashed_mark_size = CrystalClick::StreamName.hash(logical_name).bytesize + ".mrk2".bytesize
    name_floor = Math.max(name_floor, hashed_mark_size)
  end
  logical_floor = descriptor.logical_read_bytes.to_i
  descriptor.logical_read_bytes.should be > (24_u64 * 1024_u64)
  name_floor.should be < logical_floor - 1

  byte_limit_failure = ->(max_bytes : Int32) do
    begin
      read_with_limit.call(max_bytes)
      false
    rescue ex : CrystalClick::UnsupportedFormatError
      raise ex unless ex.to_s.includes?("binary codec byte limit exceeded")
      true
    rescue ex : CrystalClick::CorruptPartError
      raise ex unless ex.to_s.includes?("binary codec byte limit exceeded")
      true
    end
  end

  # This fixture has a >24 KiB ordinary String sibling. For an LC-bearing
  # schema, its bytes contribute to complete physical replay even when the
  # selected output is only a middle or zero-mark window; non-LC value
  # decoding remains selective. Probing one byte below the descriptor's full
  # logical read size distinguishes replay accounting from name limits.
  byte_limit_failure.call(logical_floor - 1).should be_true

  # Discover the monotone byte boundary against this fixture, then assert both
  # sides explicitly. The reader exposes no operation-budget counter.
  lower = logical_floor - 1
  upper = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES
  read_with_limit.call(upper).size.should eq(mark_count)
  while lower < upper
    candidate = lower + (upper - lower) // 2
    if byte_limit_failure.call(candidate)
      lower = candidate + 1
    else
      upper = candidate
    end
  end

  lower.should be >= logical_floor
  read_with_limit.call(lower).size.should eq(mark_count)
  byte_limit_failure.call(lower - 1).should be_true
  nil
end

private def w146_nullable_tuple_array_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  low_string = CrystalClick::BinaryDataType.low_cardinality(string)
  tuple = CrystalClick::BinaryDataType.tuple(
    [low_string, CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType,
    ["value", "code"] of String,
  )
  CrystalClick::BinaryDataType.tuple(
    [
      CrystalClick::BinaryDataType.nullable(tuple),
      CrystalClick::BinaryDataType.array(low_string),
    ] of CrystalClick::BinaryDataType,
    ["nullable", "items"] of String,
  )
end

private def w146_nullable_tuple_array_value(
  type : CrystalClick::BinaryDataType,
  value : String?,
  code : UInt8,
  items : Array(String),
) : CrystalClick::BinaryValue
  nullable_type = type.child_at(0)
  tuple_type = nullable_type.child_at(0)
  nullable = if label = value
               tuple = CrystalClick::BinaryValue.tuple(
                 tuple_type,
                 [
                   CrystalClick::BinaryValue.low_cardinality(
                     tuple_type.child_at(0), CrystalClick::BinaryValue.string(label)
                   ),
                   CrystalClick::BinaryValue.fixed(tuple_type.child_at(1), Bytes[code]),
                 ] of CrystalClick::BinaryValue,
               )
               CrystalClick::BinaryValue.nullable(nullable_type, tuple)
             else
               CrystalClick::BinaryValue.nullable(nullable_type)
             end
  array_type = type.child_at(1)
  array = items.map do |item|
    CrystalClick::BinaryValue.low_cardinality(array_type.child_at(0), CrystalClick::BinaryValue.string(item))
  end
  CrystalClick::BinaryValue.tuple(
    type,
    [nullable, CrystalClick::BinaryValue.array(array_type, array)] of CrystalClick::BinaryValue,
  )
end

private def w146_nullable_tuple_array_signature(value : CrystalClick::BinaryValue) : String
  nullable = value.element_at(0)
  tuple_value = if nullable.is_null?
                  "NULL"
                else
                  tuple = nullable.child_at(0)
                  "#{tuple.element_at(0).child_at(0).as_string}:#{tuple.element_at(1).bytes[0]}"
                end
  items = value.element_at(1)
  item_values = [] of String
  items.element_count.times do |index|
    item_values << items.element_at(index).child_at(0).as_string
  end
  "#{tuple_value}|[#{item_values.join(",")}]"
end

private def w146_consumer_value(
  type : CrystalClick::BinaryDataType,
  items : Array(Array(String)),
  maybe : String?,
  note : String,
) : CrystalClick::BinaryValue
  outer_type = type.child_at(0)
  inner_type = outer_type.child_at(0)
  low_string = inner_type.child_at(0)
  outer_values = items.map do |inner_items|
    low_values = inner_items.map do |item|
      CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string(item))
    end
    CrystalClick::BinaryValue.array(inner_type, low_values)
  end
  items_value = CrystalClick::BinaryValue.array(outer_type, outer_values)

  low_nullable = type.child_at(1)
  nullable_type = low_nullable.child_at(0)
  nullable_value = if value = maybe
                     CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(value))
                   else
                     CrystalClick::BinaryValue.nullable(nullable_type)
                   end
  maybe_value = CrystalClick::BinaryValue.low_cardinality(low_nullable, nullable_value)

  CrystalClick::BinaryValue.tuple(
    type,
    [items_value, maybe_value, CrystalClick::BinaryValue.string(note)] of CrystalClick::BinaryValue,
  )
end

private def w146_consumer_document(
  type : CrystalClick::BinaryDataType,
  items : Array(Array(String)),
  maybe : String?,
  note : String,
) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "payload" => w146_consumer_value(type, items, maybe, note),
  })
end

private def w146_consumer_granules(type : CrystalClick::BinaryDataType) : Array(Array(CrystalClick::ObjectDocument))
  [
    [
      w146_consumer_document(type, [["red", "red"], ["blue"]], "red", "m0-a"),
      w146_consumer_document(type, [] of Array(String), nil, "m0-b"),
    ],
    [
      # `red` and the nullable value `red` were introduced in mark zero;
      # these values therefore require dictionary/index state replay to decode
      # this selected middle mark correctly.
      w146_consumer_document(type, [["red"], [] of String], nil, "m1-a"),
      w146_consumer_document(type, [["green"]], "green", "m1-b"),
    ],
    [
      w146_consumer_document(type, [[] of String], "red", "m2-a"),
      w146_consumer_document(type, [["violet"]], nil, "m2-b"),
    ],
  ] of Array(CrystalClick::ObjectDocument)
end

private def w146_consumer_signature(value : CrystalClick::BinaryValue) : W146ObjectSignature
  item_rows = value.element_at(0)
  nested = [] of String
  item_rows.element_count.times do |outer_index|
    inner = item_rows.element_at(outer_index)
    words = [] of String
    inner.element_count.times do |inner_index|
      words << inner.element_at(inner_index).child_at(0).as_string
    end
    nested << "[#{words.join(",")}]"
  end

  nullable = value.element_at(1).child_at(0)
  maybe = if nullable.is_null?
            "NULL"
          else
            nullable.child_at(0).as_string
          end
  "#{nested.join}|#{maybe}|#{value.element_at(2).as_string}"
end

private def w146_consumer_document_signature(document : CrystalClick::ObjectDocument) : W146ObjectSignature
  w146_consumer_signature(document.value_for("payload"))
end

private def w146_consumer_catalog_table(root : String, declaration : String) : String
  database_uuid = "a1460000-0000-4000-8000-000000000146"
  table_uuid = "b1460000-0000-4000-8000-000000000146"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a14", database_uuid)
  table = File.join(root, "store", "b14", table_uuid)
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

private def with_w146_consumer_root(&)
  root = File.tempname("crystal-click-w146-object-lc-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "W146 declared Object LowCardinality consumers" do
  it "rejects same-width but nominally different LowCardinality leaves" do
    expected_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("UInt8"))
    actual_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("Bool"))
    CrystalClick::BinaryValue.fixed(expected_type.child_at(0), Bytes[1_u8]).byte_size.should eq(
      CrystalClick::BinaryValue.bool(true).byte_size
    )

    schema = CrystalClick::ObjectDocumentSchema.new({"payload" => expected_type})
    plan = w146_consumer_plan(schema)
    wrong_value = CrystalClick::BinaryValue.low_cardinality(actual_type, CrystalClick::BinaryValue.bool(true))
    document = CrystalClick::ObjectDocument.new({"payload" => wrong_value})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    end
  end

  it "composes recursive typed LC through the paired codec and replays unselected lane state" do
    schema = w146_consumer_schema
    type = w146_consumer_type
    granules = w146_consumer_granules(type)
    plan = w146_consumer_plan(schema)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, granules)
    typed = encoded.typed_for("payload")

    typed.mark_count.should eq(3)
    typed.roles.should contain("root.field.0.elements.elements.dictionary")
    typed.roles.should contain("root.field.0.elements.elements.indexes")
    typed.roles.should contain("root.field.1.dictionary")
    typed.roles.should contain("root.field.1.indexes")
    [
      "root.field.0.elements.elements.dictionary",
      "root.field.1.dictionary",
    ].each do |role|
      dictionary = typed.stream(role)
      dictionary.bytes[0, 8].should eq(Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
      dictionary.offsets.first.should eq(8_u64)
      dictionary.offsets.last.should eq(dictionary.byte_size.to_u64)
    end

    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, encoded)
    decoded.map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq([
      ["[red,red][blue]|red|m0-a", "|NULL|m0-b"],
      ["[red][]|NULL|m1-a", "[green]|green|m1-b"],
      ["[]|red|m2-a", "[violet]|NULL|m2-b"],
    ])
    middle = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, encoded, first_mark: 1, mark_count: 1)
    middle.map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq([
      ["[red][]|NULL|m1-a", "[green]|green|m1-b"],
    ])
    CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, encoded, first_mark: 3, mark_count: 0).should be_empty

    w146_assert_codec_byte_boundary(schema, encoded, 0, 3)
    w146_assert_codec_byte_boundary(schema, encoded, 1, 1)
    # Zero selected marks still replay/charge all LowCardinality state.
    w146_assert_codec_byte_boundary(schema, encoded, 3, 0)

    # Damage only the last mark's nested LC index row count. A zero-row
    # selection must still validate the complete dictionary/index history.
    index_role = "root.field.0.elements.elements.indexes"
    index_lane = typed.stream(index_role)
    damaged_indexes = index_lane.bytes
    last_mark_offset = index_lane.offset_at(2).to_i
    damaged_indexes[last_mark_offset + 8] = 0_u8
    damaged_streams = Hash(String, CrystalClick::BinaryBulkStream).new
    typed.roles.each do |role|
      lane = typed.stream(role)
      bytes = role == index_role ? damaged_indexes : lane.bytes
      damaged_streams[role] = CrystalClick::BinaryBulkStream.new(bytes, lane.offsets)
    end
    damaged_typed = CrystalClick::BinaryBulkStreams.new(typed.mark_count, damaged_streams)
    damaged_object = CrystalClick::ObjectDocumentStreams.new(
      encoded.structures,
      encoded.rows_per_mark,
      {"payload" => damaged_typed} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams,
      encoded.shared,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, damaged_object, first_mark: 3, mark_count: 0)
    end
  end

  it "keeps NULL Tuple defaults and zero-occurrence Array marks aligned with later LC state" do
    type = w146_nullable_tuple_array_type
    schema = CrystalClick::ObjectDocumentSchema.new({"payload" => type})
    granules = [
      [
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, nil, 0_u8, [] of String)}),
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, nil, 0_u8, [] of String)}),
      ],
      [
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, "red", 7_u8, ["red"])}),
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, nil, 0_u8, ["blue"])}),
      ],
      [
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, "red", 8_u8, ["blue"])}),
        CrystalClick::ObjectDocument.new({"payload" => w146_nullable_tuple_array_value(type, nil, 0_u8, ["red"])}),
      ],
    ] of Array(CrystalClick::ObjectDocument)
    plan = w146_consumer_plan(schema)
    encoded = CrystalClick::ObjectDocumentCodec.encode(plan, granules)
    typed = encoded.typed_for("payload")

    array_indexes = typed.stream("root.field.1.elements.indexes")
    array_indexes.offset_at(0).should eq(array_indexes.offset_at(1))
    array_indexes.offset_at(2).should be > array_indexes.offset_at(1)

    expected = [
      ["NULL|[]", "NULL|[]"],
      ["red:7|[red]", "NULL|[blue]"],
      ["red:8|[blue]", "NULL|[red]"],
    ]
    decode_signatures = ->(first_mark : Int32, mark_count : Int32) do
      CrystalClick::ObjectDocumentCodec.decode(
        schema.typed_paths,
        encoded,
        first_mark: first_mark,
        mark_count: mark_count,
      ).map do |mark|
        mark.map { |document| w146_nullable_tuple_array_signature(document.value_for("payload")) }
      end
    end
    decode_signatures.call(0, 3).should eq(expected)
    decode_signatures.call(1, 1).should eq([expected[1]])
    decode_signatures.call(3, 0).should be_empty
    w146_assert_codec_byte_boundary(schema, encoded, 0, 3)
    w146_assert_codec_byte_boundary(schema, encoded, 1, 1)
    w146_assert_codec_byte_boundary(schema, encoded, 3, 0)
  end

  it "writes an independent Wide Object part and reads full, selected-middle, and zero-mark windows" do
    with_w146_consumer_root do |root|
      schema = w146_consumer_schema
      type = w146_consumer_type
      plan = w146_consumer_plan(schema)
      granules = w146_consumer_granules(type)
      table_path = w146_consumer_catalog_table(root, schema.declaration)
      part = CrystalClick::WidePartWriter.write_uint64_object_pair(
        File.join(table_path, "all_1_1_0"),
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 2,
      )

      expected = [
        ["[red,red][blue]|red|m0-a", "|NULL|m0-b"],
        ["[red][]|NULL|m1-a", "[green]|green|m1-b"],
        ["[]|red|m2-a", "[violet]|NULL|m2-b"],
      ]
      low_level = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, hashed: true
      )
      low_level.map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq(expected)
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, 1, 1, hashed: true
      ).map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq([expected[1]])
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, 3, 0, hashed: true
      ).should be_empty

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.row_count.should eq(6_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.read_marks(0, 3).map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq(expected)
      reader.read_marks(1, 1).map { |mark| mark.map { |document| w146_consumer_document_signature(document) } }.should eq([expected[1]])
      reader.read_marks(3, 0).should be_empty

      # An unselected ordinary sibling makes full LC-bearing file replay
      # observable independently of dictionary/index replay. Keep this
      # oversized fixture outside the catalog table's part roster.
      large_note = ->(row : Int32) do
        String.build do |io|
          (4096 + row).times { io << 'n' }
        end
      end
      large_granules = [
        [
          w146_consumer_document(type, [["red"]], "red", large_note.call(0)),
          w146_consumer_document(type, [] of Array(String), nil, large_note.call(1)),
        ],
        [
          w146_consumer_document(type, [["red"]], nil, large_note.call(2)),
          w146_consumer_document(type, [["green"]], "green", large_note.call(3)),
        ],
        [
          w146_consumer_document(type, [[] of String], "red", large_note.call(4)),
          w146_consumer_document(type, [["violet"]], nil, large_note.call(5)),
        ],
      ] of Array(CrystalClick::ObjectDocument)
      budget_parent = File.join(root, "budget_fixture")
      Dir.mkdir_p(budget_parent)
      budget_part = CrystalClick::WidePartWriter.write_uint64_object_pair(
        File.join(budget_parent, "all_1_1_0"),
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        schema,
        plan,
        large_granules,
        rows_per_mark: 2,
      )

      # Pressure middle and zero selections; both must charge every physical
      # lane before returning their selected output.
      w146_assert_file_reader_byte_boundary(budget_part, schema, 1, 1)
      w146_assert_file_reader_byte_boundary(budget_part, schema, 3, 0)

      # The catalog path returns conservative primary-key candidates. Verify
      # that the requested rows are included and the final granule is pruned,
      # then apply the exact range residual before comparing selected rows.
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      candidate_keys = [] of UInt64
      observed = [] of Tuple(UInt64, W146ObjectSignature)
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 3_u64, upper_bound: 4_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        keys.each_with_index do |key, index|
          candidate_keys << key
          if key >= 3_u64 && key <= 4_u64
            observed << {key, w146_consumer_document_signature(documents[index])}
          end
        end
        nil
      end
      candidate_keys.includes?(3_u64).should be_true
      candidate_keys.includes?(4_u64).should be_true
      candidate_keys.includes?(5_u64).should be_false
      candidate_keys.includes?(6_u64).should be_false
      observed.should eq([
        {3_u64, "[red][]|NULL|m1-a"},
        {4_u64, "[green]|green|m1-b"},
      ])
    end
  end
end
