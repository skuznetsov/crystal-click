require "./spec_helper"
require "file_utils"

private def w189_schema_plan : Tuple(
  CrystalClick::ObjectDocumentSchema,
  CrystalClick::ObjectDocumentPlan,
)
  string = CrystalClick::BinaryDataType.primitive("String")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")

  alpha = CrystalClick::BinaryDataType.dynamic(2)
  beta = CrystalClick::BinaryDataType.dynamic(2)
  item_dynamic = CrystalClick::BinaryDataType.dynamic(2)
  items = CrystalClick::BinaryDataType.array(item_dynamic)
  choice_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  choice_array = CrystalClick::BinaryDataType.array(choice_dynamic)
  choice = CrystalClick::BinaryDataType.variant(
    [choice_array, string] of CrystalClick::BinaryDataType,
  )
  choice_array_arm = choice.children.index(choice_array).not_nil!

  schema = CrystalClick::ObjectDocumentSchema.new({
    "alpha"  => alpha,
    "beta"   => beta,
    "choice" => choice,
    "items"  => items,
  })
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  typed_dynamic_sites = {
    "choice" => {
      "root.arm.#{choice_array_arm}.elements" => CrystalClick::DynamicStructure.new([bool] of CrystalClick::BinaryDataType),
    },
    "items" => {
      "root.elements" => CrystalClick::DynamicStructure.new([uint64, string] of CrystalClick::BinaryDataType),
    },
  }
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    {
      "alpha" => CrystalClick::DynamicStructure.new([uint64, string] of CrystalClick::BinaryDataType),
      "beta"  => CrystalClick::DynamicStructure.new([bool] of CrystalClick::BinaryDataType),
    },
    typed_dynamic_sites: typed_dynamic_sites,
  )
  {schema, plan}
end

private def w189_granules : Array(Array(CrystalClick::ObjectDocument))
  string = CrystalClick::BinaryDataType.primitive("String")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  alpha_type = CrystalClick::BinaryDataType.dynamic(2)
  beta_type = CrystalClick::BinaryDataType.dynamic(2)
  item_dynamic = CrystalClick::BinaryDataType.dynamic(2)
  items_type = CrystalClick::BinaryDataType.array(item_dynamic)
  choice_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  choice_array = CrystalClick::BinaryDataType.array(choice_dynamic)
  choice_type = CrystalClick::BinaryDataType.variant(
    [choice_array, string] of CrystalClick::BinaryDataType,
  )
  choice_array_arm = choice_type.children.index(choice_array).not_nil!
  choice_string_arm = choice_type.children.index(string).not_nil!

  dynamic = ->(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue?) {
    CrystalClick::BinaryValue.dynamic(type, child)
  }
  item_array = ->(values : Array(CrystalClick::BinaryValue)) {
    CrystalClick::BinaryValue.array(items_type, values)
  }
  choice_items = ->(values : Array(CrystalClick::BinaryValue)) {
    child = CrystalClick::BinaryValue.array(choice_array, values)
    CrystalClick::BinaryValue.variant(choice_type, choice_array_arm, child)
  }
  choice_text = ->(value : String) {
    CrystalClick::BinaryValue.variant(
      choice_type,
      choice_string_arm,
      CrystalClick::BinaryValue.string(value),
    )
  }
  document = ->(alpha : CrystalClick::BinaryValue, beta : CrystalClick::BinaryValue, items : CrystalClick::BinaryValue, choice : CrystalClick::BinaryValue) {
    CrystalClick::ObjectDocument.new({
      "alpha"  => alpha,
      "beta"   => beta,
      "choice" => choice,
      "items"  => items,
    } of String => CrystalClick::BinaryValue)
  }

  [
    [
      document.call(
        dynamic.call(alpha_type, CrystalClick::BinaryValue.uint64(7_u64)),
        dynamic.call(beta_type, CrystalClick::BinaryValue.bool(true)),
        item_array.call([
          dynamic.call(item_dynamic, CrystalClick::BinaryValue.uint64(11_u64)),
          dynamic.call(item_dynamic, nil),
        ] of CrystalClick::BinaryValue),
        choice_items.call([
          dynamic.call(choice_dynamic, CrystalClick::BinaryValue.bool(false)),
        ] of CrystalClick::BinaryValue),
      ),
      document.call(
        dynamic.call(alpha_type, CrystalClick::BinaryValue.string("red")),
        dynamic.call(beta_type, nil),
        item_array.call([] of CrystalClick::BinaryValue),
        choice_text.call("plain"),
      ),
    ] of CrystalClick::ObjectDocument,
    [
      document.call(
        dynamic.call(alpha_type, nil),
        dynamic.call(beta_type, CrystalClick::BinaryValue.bool(false)),
        item_array.call([] of CrystalClick::BinaryValue),
        choice_text.call("empty"),
      ),
      document.call(
        dynamic.call(alpha_type, CrystalClick::BinaryValue.uint64(9_u64)),
        dynamic.call(beta_type, CrystalClick::BinaryValue.bool(true)),
        item_array.call([] of CrystalClick::BinaryValue),
        choice_items.call([] of CrystalClick::BinaryValue),
      ),
    ] of CrystalClick::ObjectDocument,
    [
      document.call(
        dynamic.call(alpha_type, CrystalClick::BinaryValue.string("last")),
        dynamic.call(beta_type, CrystalClick::BinaryValue.bool(false)),
        item_array.call([
          dynamic.call(item_dynamic, CrystalClick::BinaryValue.string("tail")),
        ] of CrystalClick::BinaryValue),
        choice_items.call([
          dynamic.call(choice_dynamic, nil),
          dynamic.call(choice_dynamic, CrystalClick::BinaryValue.bool(true)),
        ] of CrystalClick::BinaryValue),
      ),
      document.call(
        dynamic.call(alpha_type, CrystalClick::BinaryValue.uint64(13_u64)),
        dynamic.call(beta_type, nil),
        item_array.call([
          dynamic.call(item_dynamic, CrystalClick::BinaryValue.uint64(17_u64)),
        ] of CrystalClick::BinaryValue),
        choice_text.call("end"),
      ),
    ] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
end

private def w189_value_signature(value : CrystalClick::BinaryValue) : String
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    value.is_null? ? "DNULL" : "D(#{w189_value_signature(value.child_at(0))})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    values = (0...value.element_count).map { |index| w189_value_signature(value.element_at(index)) }
    "A[#{values.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_VARIANT
    if index = value.variant_index?
      "V#{index}(#{w189_value_signature(value.child_at(0))})"
    else
      "VNULL"
    end
  when CrystalClick::BinaryDataType::TAG_STRING
    "S(#{value.as_string})"
  when CrystalClick::BinaryDataType::TAG_BOOL
    "B(#{value.as_bool})"
  when CrystalClick::BinaryDataType::TAG_UINT64
    "U(#{value.as_uint64})"
  else
    raise "unexpected W189 value type: #{value.type.name}"
  end
end

private def w189_document_signatures(
  granules : Array(Array(CrystalClick::ObjectDocument)),
) : Array(Array(Array(String)))
  granules.map do |mark|
    mark.map do |document|
      ["alpha", "beta", "items", "choice"].map do |path|
        w189_value_signature(document.value_for(path))
      end
    end
  end
end

private def w189_expected : Array(Array(Array(String)))
  [
    [
      ["D(U(7))", "D(B(true))", "A[D(U(11)),DNULL]", "V0(A[D(B(false))])"],
      ["D(S(red))", "DNULL", "A[]", "V1(S(plain))"],
    ],
    [
      ["DNULL", "D(B(false))", "A[]", "V1(S(empty))"],
      ["D(U(9))", "D(B(true))", "A[]", "V0(A[])"],
    ],
    [
      ["D(S(last))", "D(B(false))", "A[D(S(tail))]", "V0(A[DNULL,D(B(true))])"],
      ["D(U(13))", "DNULL", "A[D(U(17))]", "V1(S(end))"],
    ],
  ] of Array(Array(String))
end

private def w189_with_bad_item_discriminator_schedule(
  streams : CrystalClick::ObjectDocumentStreams,
) : CrystalClick::ObjectDocumentStreams
  typed = Hash(String, CrystalClick::BinaryBulkStreams).new
  streams.typed_paths.each do |path|
    typed[path] = streams.typed_for(path)
  end
  dynamic = Hash(String, CrystalClick::DynamicValueStreams).new
  streams.dynamic_paths.each do |path|
    dynamic[path] = streams.dynamic_for(path)
  end

  typed_dynamic = Hash(String, CrystalClick::BinaryDynamicBulkStreams).new
  root_offsets = Hash(String, Int32).new
  site_offsets = Hash(String, Hash(String, Int32)).new
  streams.typed_dynamic_paths.each do |path|
    lanes = streams.typed_dynamic_for(path)
    roles = Hash(String, CrystalClick::BinaryBulkStream).new
    lanes.data.roles.each do |role|
      source = lanes.data.stream(role)
      if path == "items" && role == "root.elements.discriminators"
        source.byte_size.should eq(4)
        source.offsets.should eq([0_u64, 2_u64, 2_u64, 4_u64])
        # Preserve a complete monotone grid and total tag count, but change
        # the per-mark schedule from C=[2,0,2] to C'=[3,0,1].
        roles[role] = CrystalClick::BinaryBulkStream.new(
          source.bytes,
          [0_u64, 3_u64, 3_u64, 4_u64],
        )
      else
        roles[role] = source
      end
    end
    typed_dynamic[path] = CrystalClick::BinaryDynamicBulkStreams.new(
      lanes.structures,
      CrystalClick::BinaryBulkStreams.new(streams.mark_count, roles),
    )
    site_offsets[path] = Hash(String, Int32).new
    lanes.structures.site_paths.each do |site_path|
      offset = streams.typed_dynamic_site_statistics_offset(path, site_path)
      if offset
        site_offsets[path][site_path] = offset
        root_offsets[path] = offset if site_path == "root"
      end
    end
  end

  CrystalClick::ObjectDocumentStreams.new(
    streams.structures,
    streams.rows_per_mark,
    typed,
    dynamic,
    streams.shared,
    typed_dynamic,
    root_offsets,
    site_offsets,
    typed_dynamic_mode: streams.typed_dynamic_mode,
  )
end

private def w189_with_parent(&)
  parent = File.tempname("crystal-click-w189-typed-dynamic-compact-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W189 declared typed-Dynamic COMPACT Object profile" do
  it "retains a BASIC positive control for paired direct sites and recursive Dynamic fields" do
    schema, plan = w189_schema_plan
    plan.typed_dynamic_for("alpha").types.map(&.name).should eq(["UInt64", "String"])
    plan.typed_dynamic_for("beta").types.map(&.name).should eq(["Bool"])
    plan.typed_type_for("alpha").should eq(plan.typed_type_for("beta"))
    plan.typed_type_for("alpha").name.should eq("Dynamic(max_types=2)")

    streams = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      w189_granules,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
    )
    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    w189_document_signatures(decoded).should eq(w189_expected)
  end

  it "round trips paired direct Dynamic, mixed and all-empty Array(Dynamic), and a Variant choice in COMPACT" do
    schema, plan = w189_schema_plan
    marks = w189_granules
    expected = w189_expected
    plan.typed_dynamic_for("alpha").types.map(&.name).should eq(["UInt64", "String"])
    plan.typed_dynamic_for("beta").types.map(&.name).should eq(["Bool"])
    # The declared nominal Dynamic cap is equal while the actual site rosters differ.
    plan.typed_type_for("alpha").should eq(plan.typed_type_for("beta"))
    plan.typed_type_for("alpha").name.should eq("Dynamic(max_types=2)")
    marks[0].any? { |document| document.value_for("items").element_count > 0 }.should be_true
    marks[1].all? { |document| document.value_for("items").element_count == 0 }.should be_true

    streams = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      marks,
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    w189_document_signatures(CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams))
      .should eq(expected)
    w189_document_signatures(
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 1, mark_count: 1),
    ).should eq([expected[1]])
    CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      first_mark: 3,
      mark_count: 0,
    ).should be_empty

    w189_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
        "payload",
        schema,
        plan,
        marks,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
        frame_bytes: 64,
      ).should eq(part)

      full = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        hashed: true,
      )
      w189_document_signatures(full).should eq(expected)
      middle = CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 1,
        mark_count: 1,
        hashed: true,
      )
      w189_document_signatures(middle).should eq([expected[1]])
      CrystalClick::ObjectDocumentFileReader.read(
        part,
        "payload",
        schema.typed_paths,
        first_mark: 3,
        mark_count: 0,
        hashed: true,
      ).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(String)
      table.scan_typed do |batch|
        batch.object_documents_for("payload").each do |document|
          observed << ["alpha", "beta", "items", "choice"].map do |path|
            w189_value_signature(document.value_for(path))
          end
        end
      end
      observed.should eq(expected.flat_map { |mark| mark })

      middle_table = [] of Array(String)
      table.scan_typed_window(2_u64, 2) do |batch|
        batch.object_documents_for("payload").each do |document|
          middle_table << ["alpha", "beta", "items", "choice"].map do |path|
            w189_value_signature(document.value_for(path))
          end
        end
      end
      middle_table.should eq(expected[1])
      table.scan_typed_window(6_u64, 1) { raise "zero-row table window unexpectedly materialized a batch" }
    end
  end

  it "rejects a complete normalized discriminator grid whose counts disagree with its Array schedule" do
    schema, plan = w189_schema_plan
    streams = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      w189_granules,
      mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    )
    malformed = w189_with_bad_item_discriminator_schedule(streams)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, malformed)
    end
  end
end
