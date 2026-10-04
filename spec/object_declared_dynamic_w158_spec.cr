require "./spec_helper"

private def w158m_plan_and_schema : Tuple(CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan)
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  schema = CrystalClick::ObjectDocumentSchema.new({
    "alpha" => CrystalClick::BinaryDataType.dynamic(2),
    "beta"  => CrystalClick::BinaryDataType.dynamic(2),
    "plain" => string,
  })
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  rosters = {
    "alpha" => CrystalClick::DynamicStructure.new([uint64, string]),
    "beta"  => CrystalClick::DynamicStructure.new([bool]),
  }
  {schema, CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths, rosters)}
end

private def w158m_granules : Array(Array(CrystalClick::ObjectDocument))
  alpha = CrystalClick::BinaryDataType.dynamic(2)
  beta = CrystalClick::BinaryDataType.dynamic(2)
  [
    [
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha, CrystalClick::BinaryValue.string("red")),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta, CrystalClick::BinaryValue.bool(true)),
        "plain" => CrystalClick::BinaryValue.string("p0"),
      }),
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha, CrystalClick::BinaryValue.uint64(7_u64)),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta, CrystalClick::BinaryValue.string("spill")),
        "plain" => CrystalClick::BinaryValue.string("p1"),
      }),
    ],
    [
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha, CrystalClick::BinaryValue.bool(true)),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta),
        "plain" => CrystalClick::BinaryValue.string("p2"),
      }),
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha, CrystalClick::BinaryValue.string("blue")),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta, CrystalClick::BinaryValue.bool(false)),
        "plain" => CrystalClick::BinaryValue.string("p3"),
      }),
    ],
    [
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta, CrystalClick::BinaryValue.string("other")),
        "plain" => CrystalClick::BinaryValue.string("p4"),
      }),
      CrystalClick::ObjectDocument.new({
        "alpha" => CrystalClick::BinaryValue.dynamic(alpha, CrystalClick::BinaryValue.uint64(11_u64)),
        "beta"  => CrystalClick::BinaryValue.dynamic(beta, CrystalClick::BinaryValue.bool(true)),
        "plain" => CrystalClick::BinaryValue.string("p5"),
      }),
    ],
  ] of Array(CrystalClick::ObjectDocument)
end

private def w158m_signature(value : CrystalClick::BinaryValue) : String
  if value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
    return "NULL" if value.is_null?
    child = value.child_at(0)
    case child.type.name
    when "String"
      "String:#{child.as_string}"
    when "UInt64"
      "UInt64:#{child.as_uint64}"
    when "Bool"
      "Bool:#{child.as_bool}"
    else
      raise "unexpected Dynamic child type: #{child.type.name}"
    end
  else
    "String:#{value.as_string}"
  end
end

private def w158m_field_signatures(
  granules : Array(Array(CrystalClick::ObjectDocument)),
  path : String,
) : Array(Array(String))
  granules.map do |mark|
    mark.map { |document| w158m_signature(document.value_for(path)) }
  end
end

private def w158m_assert_literal_values(granules : Array(Array(CrystalClick::ObjectDocument))) : Nil
  w158m_field_signatures(granules, "alpha").should eq([
    ["String:red", "UInt64:7"],
    ["Bool:true", "String:blue"],
    ["NULL", "UInt64:11"],
  ])
  w158m_field_signatures(granules, "beta").should eq([
    ["Bool:true", "String:spill"],
    ["NULL", "Bool:false"],
    ["String:other", "Bool:true"],
  ])
  w158m_field_signatures(granules, "plain").should eq([
    ["String:p0", "String:p1"],
    ["String:p2", "String:p3"],
    ["String:p4", "String:p5"],
  ])
end

private def w158m_with_parent(&)
  parent = File.tempname("crystal-click-w158-declared-dynamic-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W158 direct declared Dynamic Object fields" do
  it "keeps typed schema paths separate from explicit Dynamic child rosters" do
    schema, plan = w158m_plan_and_schema

    schema.declaration.should eq("JSON(alpha Dynamic(max_types=2), beta Dynamic(max_types=2), plain String)")
    plan.typed_path_count.should eq(3)
    plan.typed_dynamic_count.should eq(2)
    plan.typed_dynamic_path_at(0).should eq("alpha")
    plan.typed_dynamic_path_at(1).should eq("beta")
    plan.typed_type_for("plain").should eq(CrystalClick::BinaryDataType.primitive("String"))
    plan.typed_dynamic_for("alpha").types.map(&.name).should eq(["UInt64", "String"])
    plan.typed_dynamic_for("beta").types.map(&.name).should eq(["Bool"])

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, w158m_granules, mode: 0_u64)
    streams.typed_path_count.should eq(1)
    streams.typed_path_at(0).should eq("plain")
    streams.typed_dynamic_path_count.should eq(2)
    streams.typed_dynamic_paths.should eq(["alpha", "beta"])

    full = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    w158m_assert_literal_values(full)
    middle = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths, streams, first_mark: 1, mark_count: 1
    )
    w158m_field_signatures(middle, "alpha").should eq([["Bool:true", "String:blue"]])
    w158m_field_signatures(middle, "beta").should eq([["NULL", "Bool:false"]])
    CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths, streams, first_mark: 3, mark_count: 0
    ).should be_empty
  end

  it "writes and reads the exact declared Dynamic physical roster through a complete part" do
    schema, plan = w158m_plan_and_schema
    documents = w158m_granules

    w158m_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        schema,
        plan,
        documents,
        rows_per_mark: 2,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      File.read(File.join(part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n" +
        "`payload` JSON(alpha Dynamic(max_types=2), beta Dynamic(max_types=2), plain String)\n"
      )
      File.read(File.join(part, "count.txt")).should eq("6")
      File.read(File.join(part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "14 substreams for column `payload`:\n" +
        "\tpayload.alpha.SharedVariant\n\tpayload.alpha.String\n\tpayload.alpha.UInt64\n" +
        "\tpayload.alpha.dynamic_structure\n\tpayload.alpha.variant_discr\n" +
        "\tpayload.beta.Bool\n\tpayload.beta.SharedVariant\n\tpayload.beta.dynamic_structure\n" +
        "\tpayload.beta.variant_discr\n\tpayload.object_shared_data%2Epaths\n" +
        "\tpayload.object_shared_data%2Evalues\n\tpayload.object_shared_data.size0\n" +
        "\tpayload.object_structure\n\tpayload.plain\n"
      )

      full = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      w158m_assert_literal_values(full)
      middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      w158m_field_signatures(middle, "alpha").should eq([["Bool:true", "String:blue"]])
      w158m_field_signatures(middle, "beta").should eq([["NULL", "Bool:false"]])
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 3, mark_count: 0, hashed: true
      ).should be_empty

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      w158m_assert_literal_values(reader.read_marks(0, 3))
      w158m_field_signatures(reader.read_marks(1, 1), "alpha").should eq([["Bool:true", "String:blue"]])
      reader.read_marks(3, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      table.total_row_count.should eq(6_u64)
      table.column_types.should eq([{"payload", "JSON(alpha Dynamic(max_types=2), beta Dynamic(max_types=2), plain String)"}])
      observed_alpha = [] of String
      observed_beta = [] of String
      observed_plain = [] of String
      table.scan_typed do |batch|
        batch.object_documents_for("payload").each do |document|
          observed_alpha << w158m_signature(document.value_for("alpha"))
          observed_beta << w158m_signature(document.value_for("beta"))
          observed_plain << w158m_signature(document.value_for("plain"))
        end
      end
      observed_alpha.should eq(["String:red", "UInt64:7", "Bool:true", "String:blue", "NULL", "UInt64:11"])
      observed_beta.should eq(["Bool:true", "String:spill", "NULL", "Bool:false", "String:other", "Bool:true"])
      observed_plain.should eq(["String:p0", "String:p1", "String:p2", "String:p3", "String:p4", "String:p5"])
    end
  end

  it "rejects malformed or noncanonical Dynamic cap spelling and inexact actual rosters" do
    [
      "JSON(a Dynamic(max_types=01))",
      "JSON(a Dynamic(max_types=32))",
      "JSON(a Dynamic(max_types=255))",
      "JSON(a Dynamic(max_types=2)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
    whitespace_normalized = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(a Dynamic(max_types=2) )"
    )
    whitespace_normalized.declaration.should eq("JSON(a Dynamic(max_types=2))")
    whitespace_normalized.typed_paths.should eq({"a" => CrystalClick::BinaryDataType.dynamic(2)})

    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({
      "a" => CrystalClick::BinaryDataType.dynamic(0),
      "b" => CrystalClick::BinaryDataType.dynamic(1),
    })
    bool = CrystalClick::BinaryDataType.primitive("Bool")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, schema.typed_paths, {"a" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, schema.typed_paths, {
        "a"     => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        "b"     => CrystalClick::DynamicStructure.new([bool]),
        "extra" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      })
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(empty, schema.typed_paths, {
        "a" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        "b" => CrystalClick::DynamicStructure.new([bool, uint64]),
      })
    end

    zero_cap_plan = CrystalClick::ObjectDocumentPlan.new(empty, {"a" => CrystalClick::BinaryDataType.dynamic(0)}, {
      "a" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })
    zero_streams = CrystalClick::ObjectDocumentCodec.encode(zero_cap_plan, [[
      CrystalClick::ObjectDocument.new({"a" => CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic(0))}),
      CrystalClick::ObjectDocument.new({"a" => CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic(0), CrystalClick::BinaryValue.string("shared"))}),
    ]], mode: 0_u64)
    decoded = CrystalClick::ObjectDocumentCodec.decode({"a" => CrystalClick::BinaryDataType.dynamic(0)}, zero_streams)
    w158m_field_signatures(decoded, "a").should eq([["NULL", "String:shared"]])
  end

  it "retains an unused Array alternative beside NULL and SharedVariant spill" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    array = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    schema = CrystalClick::ObjectDocumentSchema.new({"value" => dynamic})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      {"value" => CrystalClick::DynamicStructure.new([array])},
    )
    documents = [[
      CrystalClick::ObjectDocument.new({"value" => CrystalClick::BinaryValue.dynamic(dynamic)}),
      CrystalClick::ObjectDocument.new({"value" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("shared"))}),
    ]] of Array(CrystalClick::ObjectDocument)

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents, mode: 0_u64)
    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    w158m_field_signatures(decoded, "value").should eq([["NULL", "String:shared"]])

    w158m_with_parent do |parent|
      part = File.join(parent, "array_arm")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part, "pk", Slice[1_u64, 2_u64], "payload", schema, plan, documents,
        rows_per_mark: 2, mode: 0_u64, frame_bytes: 64
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      names = physical.stream_names
      names.any?(&.starts_with?("payload.value.Array%28UInt8%29")).should be_true
      names.should contain("payload.value.dynamic_structure")
      names.should contain("payload.value.variant_discr")
      readback = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      w158m_field_signatures(readback, "value").should eq([["NULL", "String:shared"]])
    end
  end
end
