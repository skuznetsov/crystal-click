require "./spec_helper"

private def w186_recursive_limits(
  max_depth : Int = 16,
  max_nodes : Int = 4_096,
  max_elements : Int = 8_192,
  max_bytes : Int = 1_048_576,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w186_recursive_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def with_w186_recursive_part_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w186-recursive-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w186_recursive_mixed_row(
  bulk_type : CrystalClick::BinaryDataType,
  document_byte : UInt8,
  label : String,
  variant_value : CrystalClick::BinaryValue,
  sequence : UInt64,
) : CrystalClick::StorageColumnValue
  document = CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[document_byte]
    ),
  })
  bulk = CrystalClick::BinaryValue.tuple(
    bulk_type,
    [
      CrystalClick::BinaryValue.low_cardinality(
        bulk_type.child_at(0), CrystalClick::BinaryValue.string(label)
      ),
      variant_value,
      CrystalClick::BinaryValue.uint64(sequence),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(document),
    CrystalClick::StorageColumnValue.bulk(bulk),
  ] of CrystalClick::StorageColumnValue)
end

private def w186_assert_recursive_mixed_row(
  row : CrystalClick::StorageColumnValue,
  document_byte : UInt8,
  label : String,
  variant_index : UInt8,
  variant_string : String?,
  variant_byte : UInt8,
  sequence : UInt64,
) : Nil
  row.tuple?.should be_true
  row.child_count.should eq(2)
  row.child_at(0).object_document.value_for("t").bytes.should eq(Bytes[document_byte])

  bulk = row.child_at(1).bulk_value
  bulk.type.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)
  bulk.child_at(0).child_at(0).as_string.should eq(label)
  variant = bulk.child_at(1)
  variant.variant_index?.should eq(variant_index)
  if expected_string = variant_string
    variant.variant_child?.not_nil!.as_string.should eq(expected_string)
  else
    variant.variant_child?.not_nil!.bytes.should eq(Bytes[variant_byte])
  end
  bulk.child_at(2).as_uint64.should eq(sequence)
  nil
end

describe "W186 recursive Tuple column composition" do
  it "uses inherited Tuple depth for Object typed descriptors" do
    direct = "Tuple(item JSON(t UInt8))"
    nested = "Tuple(outer Tuple(item JSON(t Array(UInt8))))"

    CrystalClick::StorageColumnSchema.parse(direct, w186_recursive_limits(max_depth: 2)).declaration.should eq(direct)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnSchema.parse(direct, w186_recursive_limits(max_depth: 1))
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnSchema.parse(nested, w186_recursive_limits(max_depth: 3))
    end
    nested_schema = CrystalClick::StorageColumnSchema.parse(nested, w186_recursive_limits(max_depth: 4))
    nested_schema.declaration.should eq(nested)
    nested_schema.json_site_keys.should eq(["root/tuple[0]/tuple[0]"])
  end

  it "admits eleven equal JSON sites with stable index identities despite lexicographic key order" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    declaration = String.build do |io|
      io << "Tuple("
      11.times do |index|
        io << ", " if index > 0
        io << "f" << index << " " << json_schema.declaration
      end
      io << ')'
    end
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    schema.json_site_keys.size.should eq(11)

    object_plan = w186_recursive_object_plan(json_schema)
    plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
    schema.json_site_keys.each do |key|
      plans[key] = object_plan
    end

    plan = CrystalClick::RecursiveStorageColumnPlan.for_column("value", schema, plans)
    plan.object_site_count.should eq(11)
    plan.object_site_at(2).key.should eq("root/tuple[2]")
    plan.object_site_at(10).key.should eq("root/tuple[10]")
    plan.object_site_at(10).prefix.should_not eq(plan.object_site_at(2).prefix)
  end

  it "publishes and reads a JSON leaf beneath a nested Tuple at full and middle windows" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(group Tuple(doc #{json_schema.declaration}, sequence UInt64))"
    )
    schema.json_site_keys.should eq(["root/tuple[0]/tuple[0]"])
    object_plan = w186_recursive_object_plan(json_schema)
    plans = {"root/tuple[0]/tuple[0]" => object_plan}

    rows = [
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.tuple([
          CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new({
            "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[3_u8]),
          })),
          CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(101_u64)),
        ] of CrystalClick::StorageColumnValue),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.tuple([
          CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new({
            "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[29_u8]),
          })),
          CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(211_u64)),
        ] of CrystalClick::StorageColumnValue),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.tuple([
          CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new({
            "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[47_u8]),
          })),
          CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(307_u64)),
        ] of CrystalClick::StorageColumnValue),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
    granules = rows.map { |row| [row] of CrystalClick::StorageColumnValue }

    with_w186_recursive_part_parent("nested-tuple-json") do |parent|
      destination = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        destination,
        "pk",
        Slice[5_u64, 8_u64, 13_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
      ).should eq(destination)

      reader = CrystalClick::RecursiveStorageColumnReader.open(destination, "payload", schema)
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      full = reader.read_marks(0, 3)
      full.size.should eq(3)
      [[3_u8, 101_u64], [29_u8, 211_u64], [47_u8, 307_u64]].each_with_index do |expected, index|
        nested = full[index][0].child_at(0)
        nested.tuple?.should be_true
        nested.child_count.should eq(2)
        nested.child_at(0).object_document.value_for("t").bytes.should eq(Bytes[expected[0]])
        nested.child_at(1).bulk_value.as_uint64.should eq(expected[1])
      end

      middle = reader.read_marks(1, 1)
      middle.size.should eq(1)
      middle[0].size.should eq(1)
      nested = middle[0][0].child_at(0)
      nested.child_at(0).object_document.value_for("t").bytes.should eq(Bytes[29_u8])
      nested.child_at(1).bulk_value.as_uint64.should eq(211_u64)
    end
  end

  it "publishes and reopens nested Tuple JSON plus LowCardinality and Variant Bulk state" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    variant_type = CrystalClick::BinaryDataType.variant([
      string_type,
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    bulk_type = CrystalClick::BinaryDataType.tuple(
      [
        low_cardinality_type,
        variant_type,
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ] of CrystalClick::BinaryDataType,
      ["label", "choice", "sequence"],
    )
    declaration = "Tuple(doc #{json_schema.declaration}, bulk #{bulk_type.name})"
    schema = CrystalClick::StorageColumnSchema.parse(declaration)
    object_plan = w186_recursive_object_plan(json_schema)
    plans = {"root/tuple[0]" => object_plan}
    string_index = variant_type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_STRING ? 0 : 1
    uint8_index = 1 - string_index
    rows = [
      w186_recursive_mixed_row(
        bulk_type, 7_u8, "oak",
        CrystalClick::BinaryValue.variant(variant_type, string_index, CrystalClick::BinaryValue.string("north")),
        10_u64,
      ),
      w186_recursive_mixed_row(
        bulk_type, 11_u8, "oak",
        CrystalClick::BinaryValue.variant(
          variant_type, uint8_index,
          CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[21_u8]),
        ),
        20_u64,
      ),
      w186_recursive_mixed_row(
        bulk_type, 17_u8, "pine",
        CrystalClick::BinaryValue.variant(variant_type, string_index, CrystalClick::BinaryValue.string("south")),
        30_u64,
      ),
    ] of CrystalClick::StorageColumnValue
    granules = rows.map { |row| [row] of CrystalClick::StorageColumnValue }

    with_w186_recursive_part_parent("bulk-replay") do |parent|
      destination = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        destination,
        "pk",
        Slice[1_u64, 2_u64, 3_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
      ).should eq(destination)

      reader = CrystalClick::RecursiveStorageColumnReader.open(destination, "payload", schema)
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      names = reader.physical_stream_names
      names.should contain("payload%2Ebulk%2Elabel.dict")
      names.should contain("payload%2Ebulk%2Elabel")
      names.should contain("payload%2Ebulk%2Echoice.variant_discr")

      full = reader.read_marks(0, 3)
      full.size.should eq(3)
      w186_assert_recursive_mixed_row(full[0][0], 7_u8, "oak", string_index.to_u8, "north", 0_u8, 10_u64)
      w186_assert_recursive_mixed_row(full[1][0], 11_u8, "oak", uint8_index.to_u8, nil, 21_u8, 20_u64)
      w186_assert_recursive_mixed_row(full[2][0], 17_u8, "pine", string_index.to_u8, "south", 0_u8, 30_u64)

      middle = reader.read_marks(1, 1)
      middle.size.should eq(1)
      middle[0].size.should eq(1)
      w186_assert_recursive_mixed_row(middle[0][0], 11_u8, "oak", uint8_index.to_u8, nil, 21_u8, 20_u64)

      checksums_before = File.read(File.join(destination, "checksums.txt"))
      expect_raises(ArgumentError, "destination must not already exist") do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          destination, "pk", Slice[1_u64, 2_u64, 3_u64], "payload", schema, plans, granules,
          rows_per_mark: 1,
        )
      end
      File.read(File.join(destination, "checksums.txt")).should eq(checksums_before)
      Dir.children(parent).should eq(["part"] of String)
    end
  end

  it "rejects invalid site rosters, malformed public trees, physical prefix collisions, and unsupported shared profiles before staging" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse("Tuple(doc #{json_schema.declaration})")
    object_plan = w186_recursive_object_plan(json_schema)
    expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column("payload", schema, {} of String => CrystalClick::ObjectDocumentPlan)
    end

    malformed = CrystalClick::StorageColumnSchema.tuple(
      "Tuple(doc JSON(t UInt8))",
      true,
      ["doc"],
      ["doc"],
      [CrystalClick::StorageColumnSchema.bulk(CrystalClick::BinaryDataType.primitive("UInt8"), "JSON(t UInt8)")],
    )
    expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column("payload", malformed, {"root/tuple[0]" => object_plan})
    end

    colliding = CrystalClick::StorageColumnSchema.parse(
      "Tuple(`a.b` JSON(t UInt8), a Tuple(b JSON(t UInt8)))"
    )
    two_plans = {
      "root/tuple[0]"          => object_plan,
      "root/tuple[1]/tuple[0]" => object_plan,
    }
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column("payload", colliding, two_plans)
    end

    row = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(
        CrystalClick::ObjectDocument.new({
          "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[1_u8]),
        })
      ),
    ] of CrystalClick::StorageColumnValue)
    with_w186_recursive_part_parent("preflight") do |parent|
      target = File.join(parent, "part")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          target,
          "pk",
          Slice[1_u64],
          "payload",
          schema,
          {"root/tuple[0]" => object_plan},
          [[row]] of Array(CrystalClick::StorageColumnValue),
          shared_profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          target,
          "pk",
          Slice[1_u64, 2_u64],
          "payload",
          schema,
          {"root/tuple[0]" => object_plan},
          [[row]] of Array(CrystalClick::StorageColumnValue),
          rows_per_mark: 1,
        )
      end
      Dir.children(parent).should be_empty
    end
  end

  it "keeps one transport budget across sibling JSON sites and refuses a late-site overflow before staging" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    object_plan = w186_recursive_object_plan(json_schema)
    document = CrystalClick::ObjectDocument.new({
      "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[9_u8]),
    })
    one_schema = CrystalClick::StorageColumnSchema.parse("Tuple(doc #{json_schema.declaration})")
    one_row = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
    ] of CrystalClick::StorageColumnValue)
    one_plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", one_schema, {"root/tuple[0]" => object_plan}
    )
    one_files = CrystalClick::RecursiveStorageColumnWriter.encode(
      one_plan,
      [[one_row]] of Array(CrystalClick::StorageColumnValue),
    )
    one_site_bytes = 0_i64
    one_files.file_names.each do |name|
      one_site_bytes += one_files.file_bytes(name).size.to_i64
    end

    two_schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(left #{json_schema.declaration}, right #{json_schema.declaration})"
    )
    two_row = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
      CrystalClick::StorageColumnValue.object_document(document),
    ] of CrystalClick::StorageColumnValue)
    two_plans = {
      "root/tuple[0]" => object_plan,
      "root/tuple[1]" => object_plan,
    }

    with_w186_recursive_part_parent("late-site-limit") do |parent|
      target = File.join(parent, "part")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          target,
          "pk",
          Slice[1_u64],
          "payload",
          two_schema,
          two_plans,
          [[two_row]] of Array(CrystalClick::StorageColumnValue),
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_file_bytes: one_site_bytes),
        )
      end
      Dir.children(parent).should be_empty
    end
  end
end
