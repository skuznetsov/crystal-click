require "./spec_helper"

private def w151_consumer_array_type : CrystalClick::BinaryDataType
  variant = CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String")),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
  variant.children.map(&.name).should eq(["LowCardinality(String)", "UInt64"] of String)
  CrystalClick::BinaryDataType.array(variant)
end

private def w151_consumer_low_variant(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
  low = type.child_at(0)
  child = CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(value))
  CrystalClick::BinaryValue.variant(type, 0, child)
end

private def w151_consumer_uint_variant(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(value))
end

private def w151_consumer_array(type : CrystalClick::BinaryDataType, values : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.array(type, values)
end

private def w151_consumer_large_string : String
  String.build do |io|
    8192.times { io << 'x' }
  end
end

private def w151_consumer_document(value : CrystalClick::BinaryValue) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({"payload" => value})
end

private def w151_consumer_granules(type : CrystalClick::BinaryDataType, large : Bool = false) : Array(Array(CrystalClick::ObjectDocument))
  variant = type.child_at(0)
  [
    [
      w151_consumer_document(w151_consumer_array(type, [
        w151_consumer_low_variant(variant, large ? w151_consumer_large_string : "red"),
        w151_consumer_uint_variant(variant, 11_u64),
      ] of CrystalClick::BinaryValue)),
      w151_consumer_document(w151_consumer_array(type, [] of CrystalClick::BinaryValue)),
    ],
    [
      # This mark has no ordinary arm payload. Its NULL discriminators still
      # occupy the Variant lane, while the empty Array has no child rows.
      w151_consumer_document(w151_consumer_array(type, [
        CrystalClick::BinaryValue.variant_null(variant),
      ] of CrystalClick::BinaryValue)),
      w151_consumer_document(w151_consumer_array(type, [
        CrystalClick::BinaryValue.variant_null(variant),
      ] of CrystalClick::BinaryValue)),
    ],
    [
      w151_consumer_document(w151_consumer_array(type, [
        w151_consumer_low_variant(variant, "blue"),
        w151_consumer_uint_variant(variant, 33_u64),
      ] of CrystalClick::BinaryValue)),
      w151_consumer_document(w151_consumer_array(type, [
        w151_consumer_low_variant(variant, "red"),
      ] of CrystalClick::BinaryValue)),
    ],
  ] of Array(CrystalClick::ObjectDocument)
end

private def w151_consumer_signature(value : CrystalClick::BinaryValue) : String
  parts = [] of String
  value.element_count.times do |index|
    variant = value.element_at(index)
    if variant.is_null?
      parts << "NULL"
    else
      case variant.variant_index?.not_nil!
      when 0
        text = variant.variant_child?.not_nil!.child_at(0).as_string
        if text.bytesize > 64
          text.should eq(w151_consumer_large_string)
          parts << "S:large:#{text.bytesize}"
        else
          parts << "S:#{text}"
        end
      when 1
        parts << "U:#{variant.variant_child?.not_nil!.as_uint64}"
      else
        raise "unexpected Variant arm index"
      end
    end
  end
  "[#{parts.join(",")}]"
end

private def w151_consumer_document_signature(document : CrystalClick::ObjectDocument) : String
  w151_consumer_signature(document.value_for("payload"))
end

private def w151_consumer_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w151_consumer_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
    max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
    max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
    max_bytes: max_bytes,
  )
end

private def w151_assert_codec_byte_boundary(
  schema : CrystalClick::ObjectDocumentSchema,
  streams : CrystalClick::ObjectDocumentStreams,
  first_mark : Int,
  mark_count : Int,
) : Nil
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  CrystalClick::ObjectDocumentCodec.decode_with_budget(
    schema.typed_paths,
    streams,
    measured,
    first_mark,
    mark_count,
  ).size.should eq(mark_count)
  exact = w151_consumer_limits(measured.wire_byte_count.to_i)
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
      limits: w151_consumer_limits(measured.wire_byte_count.to_i - 1),
    )
  end
  nil
end

private def w151_consumer_table(root : String, declaration : String) : String
  database_uuid = "a1510000-0000-4000-8000-000000000151"
  table_uuid = "b1510000-0000-4000-8000-000000000151"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a15", database_uuid)
  table = File.join(root, "store", "b15", table_uuid)
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

private def with_w151_consumer_root(&)
  root = File.tempname("crystal-click-w151-object-variant-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "W151 declared Object Variant consumers" do
  it "round-trips Array(Variant(LC, UInt64)), replays LC census, and charges exact codec bytes" do
    type = w151_consumer_array_type
    schema = CrystalClick::ObjectDocumentSchema.new({"payload" => type})
    granules = w151_consumer_granules(type)
    encoded = CrystalClick::ObjectDocumentCodec.encode(w151_consumer_plan(schema), granules)
    typed = encoded.typed_for("payload")

    typed.roles.should contain("root.elements.arm.0.dictionary")
    typed.roles.should contain("root.elements.arm.0.indexes")
    typed.roles.should contain("root.elements.arm.1.data")
    typed.roles.should contain("root.elements.discriminators")
    typed.roles.should contain("root.sizes")
    typed.stream("root.elements.discriminators").bytes.should eq(
      Bytes[0_u8, 1_u8, 0xff_u8, 0xff_u8, 0_u8, 1_u8, 0_u8]
    )

    expected = [
      ["[S:red,U:11]", "[]"],
      ["[NULL]", "[NULL]"],
      ["[S:blue,U:33]", "[S:red]"],
    ]
    decode = ->(first_mark : Int32, mark_count : Int32) do
      CrystalClick::ObjectDocumentCodec.decode(
        schema.typed_paths,
        encoded,
        first_mark: first_mark,
        mark_count: mark_count,
      ).map do |mark|
        mark.map { |document| w151_consumer_document_signature(document) }
      end
    end
    decode.call(0, 3).should eq(expected)
    decode.call(1, 1).should eq([expected[1]])
    decode.call(3, 0).should be_empty
    w151_assert_codec_byte_boundary(schema, encoded, 0, 3)
    w151_assert_codec_byte_boundary(schema, encoded, 1, 1)
    w151_assert_codec_byte_boundary(schema, encoded, 3, 0)

    # An invalid discriminator in an unselected mark is still examined when
    # this typed tree contains LowCardinality and requires its global census.
    discriminator_role = "root.elements.discriminators"
    discriminator_lane = typed.stream(discriminator_role)
    damaged = discriminator_lane.bytes
    damaged[discriminator_lane.offset_at(2).to_i] = 0xfe_u8
    damaged_streams = Hash(String, CrystalClick::BinaryBulkStream).new
    typed.roles.each do |role|
      lane = typed.stream(role)
      bytes = role == discriminator_role ? damaged : lane.bytes
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
    [
      {1, 1},
      {3, 0},
    ].each do |window|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentCodec.decode(
          schema.typed_paths,
          damaged_object,
          first_mark: window[0],
          mark_count: window[1],
        )
      end
    end
  end

  it "writes and reads complete physical/public consumers for full, middle, and zero windows" do
    with_w151_consumer_root do |root|
      type = w151_consumer_array_type
      schema = CrystalClick::ObjectDocumentSchema.new({"payload" => type})
      plan = w151_consumer_plan(schema)
      table_path = w151_consumer_table(root, schema.declaration)
      part = CrystalClick::WidePartWriter.write_uint64_object_pair(
        File.join(table_path, "all_1_1_0"),
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        schema,
        plan,
        w151_consumer_granules(type, large: true),
        rows_per_mark: 2,
      )
      expected = [
        ["[S:large:8192,U:11]", "[]"],
        ["[NULL]", "[NULL]"],
        ["[S:blue,U:33]", "[S:red]"],
      ]
      signature_marks = ->(marks : Array(Array(CrystalClick::ObjectDocument))) do
        marks.map { |mark| mark.map { |document| w151_consumer_document_signature(document) } }
      end

      signature_marks.call(CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, hashed: true
      )).should eq(expected)
      signature_marks.call(CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, 1, 1, hashed: true
      )).should eq([expected[1]])
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, 3, 0, hashed: true
      ).should be_empty

      column = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      column.row_count.should eq(6_u64)
      column.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      signature_marks.call(column.read_marks(0, 3)).should eq(expected)
      signature_marks.call(column.read_marks(1, 1)).should eq([expected[1]])
      column.read_marks(3, 0).should be_empty

      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      candidate_keys = [] of UInt64
      observed = [] of Tuple(UInt64, String)
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 3_u64, upper_bound: 4_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        keys.each_with_index do |key, index|
          candidate_keys << key
          if key >= 3_u64 && key <= 4_u64
            observed << {key, w151_consumer_document_signature(documents[index])}
          end
        end
        nil
      end
      candidate_keys.includes?(3_u64).should be_true
      candidate_keys.includes?(4_u64).should be_true
      candidate_keys.includes?(5_u64).should be_false
      candidate_keys.includes?(6_u64).should be_false
      observed.should eq([
        {3_u64, "[NULL]"},
        {4_u64, "[NULL]"},
      ])

      descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
        part, "payload", schema.typed_paths, hashed: true
      )
      full_lane_floor = descriptor.logical_read_bytes.to_i
      full_lane_floor.should be > 1
      [
        {1, 1},
        {3, 0},
      ].each do |window|
        byte_limit_failure = begin
          CrystalClick::ObjectDocumentFileReader.read(
            part,
            "payload",
            schema.typed_paths,
            window[0],
            window[1],
            hashed: true,
            limits: w151_consumer_limits(full_lane_floor - 1),
          )
          false
        rescue ex : CrystalClick::UnsupportedFormatError
          raise ex unless ex.to_s.includes?("binary codec byte limit exceeded")
          true
        rescue ex : CrystalClick::CorruptPartError
          raise ex unless ex.to_s.includes?("binary codec byte limit exceeded")
          true
        end
        byte_limit_failure.should be_true
      end
    end
  end
end
