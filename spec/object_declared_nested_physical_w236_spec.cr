require "file_utils"
require "./spec_helper"

private class W236PCase
  getter id : String
  getter type : CrystalClick::BinaryDataType
  getter schema : CrystalClick::ObjectDocumentSchema
  getter plan : CrystalClick::ObjectDocumentPlan
  getter values : Array(CrystalClick::BinaryValue?)
  getter expected : Array(String)

  def initialize(
    @id : String,
    @type : CrystalClick::BinaryDataType,
    @values : Array(CrystalClick::BinaryValue?),
    @expected : Array(String),
  )
    @schema = CrystalClick::ObjectDocumentSchema.new({"q" => @type} of String => CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    @plan = CrystalClick::ObjectDocumentPlan.new(structures, @schema.typed_paths)
  end

  def granules : Array(Array(CrystalClick::ObjectDocument))
    documents = Array(CrystalClick::ObjectDocument).new(@values.size)
    @values.each do |maybe_value|
      value = maybe_value || CrystalClick::BinaryBulkDefaultValue.build(@type)
      documents << CrystalClick::ObjectDocument.new(
        {"q" => value} of String => CrystalClick::BinaryValue,
      )
    end
    unless documents.size == 6
      raise "W236 physical fixture must contain six parent rows"
    end
    [
      [documents[0], documents[1]] of CrystalClick::ObjectDocument,
      [documents[2], documents[3]] of CrystalClick::ObjectDocument,
      [documents[4], documents[5]] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
  end
end

private def w236p_u8(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(type, Bytes[value])
end

private def w236p_nested(
  type : CrystalClick::BinaryDataType,
  rows : Array(Tuple(UInt8, String)),
) : CrystalClick::BinaryValue
  tuple = type.child_at(0)
  number_type = tuple.child_at(0)
  string_type = tuple.child_at(1)
  records = rows.map do |row|
    CrystalClick::BinaryValue.tuple(
      tuple,
      [w236p_u8(number_type, row[0]), CrystalClick::BinaryValue.string(row[1])] of CrystalClick::BinaryValue,
    )
  end
  CrystalClick::BinaryValue.nested(type, records)
end

private def w236p_cases : Array(W236PCase)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  nested = CrystalClick::BinaryDataType.nested(
    [uint8, string] of CrystalClick::BinaryDataType,
    ["n", "s"] of String,
  )
  array_nested = CrystalClick::BinaryDataType.array(nested)
  tuple_nested = CrystalClick::BinaryDataType.tuple(
    [nested, uint8] of CrystalClick::BinaryDataType,
    ["items", "tag"] of String,
  )
  map_nested = CrystalClick::BinaryDataType.map(string, nested)
  variant_nested = CrystalClick::BinaryDataType.variant(
    [nested, string] of CrystalClick::BinaryDataType,
  )

  empty_nested = -> { w236p_nested(nested, [] of Tuple(UInt8, String)) }
  direct_values = [
    w236p_nested(nested, [{1_u8, "a"}, {2_u8, "long"}] of Tuple(UInt8, String)),
    empty_nested.call,
    nil,
    w236p_nested(nested, [{255_u8, "x"}] of Tuple(UInt8, String)),
    w236p_nested(nested, [{0_u8, "left"}, {17_u8, "r"}, {42_u8, "longer-right"}] of Tuple(UInt8, String)),
    nil,
  ] of CrystalClick::BinaryValue?

  array_values = [
    CrystalClick::BinaryValue.array(array_nested, [
      w236p_nested(nested, [{1_u8, "a"}, {2_u8, "long"}] of Tuple(UInt8, String)),
      w236p_nested(nested, [{3_u8, "m"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(array_nested, [] of CrystalClick::BinaryValue),
    nil,
    CrystalClick::BinaryValue.array(array_nested, [empty_nested.call] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(array_nested, [
      w236p_nested(nested, [{0_u8, "left"}, {17_u8, "r"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(array_nested, [
      w236p_nested(nested, [{4_u8, "tail"}, {8_u8, "x"}] of Tuple(UInt8, String)),
      w236p_nested(nested, [{9_u8, "long"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
  ] of CrystalClick::BinaryValue?

  tuple_values = [
    CrystalClick::BinaryValue.tuple(tuple_nested, [
      w236p_nested(nested, [{1_u8, "t"}, {2_u8, "side"}] of Tuple(UInt8, String)),
      w236p_u8(uint8, 7_u8),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.tuple(tuple_nested, [
      empty_nested.call,
      w236p_u8(uint8, 9_u8),
    ] of CrystalClick::BinaryValue),
    nil,
    CrystalClick::BinaryValue.tuple(tuple_nested, [
      w236p_nested(nested, [{255_u8, "x"}] of Tuple(UInt8, String)),
      w236p_u8(uint8, 255_u8),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.tuple(tuple_nested, [
      w236p_nested(nested, [{0_u8, "left"}, {17_u8, "r"}, {42_u8, "longer-right"}] of Tuple(UInt8, String)),
      w236p_u8(uint8, 5_u8),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.tuple(tuple_nested, [empty_nested.call, w236p_u8(uint8, 0_u8)] of CrystalClick::BinaryValue),
  ] of CrystalClick::BinaryValue?

  map_values = [
    CrystalClick::BinaryValue.map(map_nested, [
      CrystalClick::BinaryValue.string("a"),
      w236p_nested(nested, [{1_u8, "a"}, {2_u8, "long"}] of Tuple(UInt8, String)),
      CrystalClick::BinaryValue.string("long-key"),
      w236p_nested(nested, [{3_u8, "m"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.map(map_nested, [] of CrystalClick::BinaryValue),
    nil,
    CrystalClick::BinaryValue.map(map_nested, [CrystalClick::BinaryValue.string("x"), empty_nested.call] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.map(map_nested, [
      CrystalClick::BinaryValue.string("left"),
      w236p_nested(nested, [{0_u8, "left"}, {17_u8, "r"}, {42_u8, "longer-right"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.map(map_nested, [
      CrystalClick::BinaryValue.string("tail"),
      w236p_nested(nested, [{9_u8, "z"}] of Tuple(UInt8, String)),
    ] of CrystalClick::BinaryValue),
  ] of CrystalClick::BinaryValue?

  nested_arm = variant_nested.children.index(nested).not_nil!
  string_arm = variant_nested.children.index(string).not_nil!
  variant_values = [
    CrystalClick::BinaryValue.variant(
      variant_nested, nested_arm,
      w236p_nested(nested, [{1_u8, "a"}, {2_u8, "long"}] of Tuple(UInt8, String)),
    ),
    CrystalClick::BinaryValue.variant(variant_nested, string_arm, CrystalClick::BinaryValue.string("v")),
    nil,
    CrystalClick::BinaryValue.variant(variant_nested, nested_arm, w236p_nested(nested, [{255_u8, "x"}] of Tuple(UInt8, String))),
    CrystalClick::BinaryValue.variant(variant_nested, string_arm, CrystalClick::BinaryValue.string("much-longer")),
    CrystalClick::BinaryValue.variant(
      variant_nested, nested_arm,
      w236p_nested(nested, [{0_u8, "left"}, {17_u8, "r"}, {42_u8, "longer-right"}] of Tuple(UInt8, String)),
    ),
  ] of CrystalClick::BinaryValue?

  [
    W236PCase.new(
      "direct_nested", nested, direct_values,
      ["N[(1,a),(2,long)]", "N[]", "N[]", "N[(255,x)]", "N[(0,left),(17,r),(42,longer-right)]", "N[]"],
    ),
    W236PCase.new(
      "array_nested", array_nested, array_values,
      ["A[N[(1,a),(2,long)],N[(3,m)]]", "A[]", "A[]", "A[N[]]", "A[N[(0,left),(17,r)]]", "A[N[(4,tail),(8,x)],N[(9,long)]]"],
    ),
    W236PCase.new(
      "tuple_nested", tuple_nested, tuple_values,
      ["T(N[(1,t),(2,side)],7)", "T(N[],9)", "T(N[],0)", "T(N[(255,x)],255)", "T(N[(0,left),(17,r),(42,longer-right)],5)", "T(N[],0)"],
    ),
    W236PCase.new(
      "map_nested", map_nested, map_values,
      ["M[a=>N[(1,a),(2,long)],long-key=>N[(3,m)]]", "M[]", "M[]", "M[x=>N[]]", "M[left=>N[(0,left),(17,r),(42,longer-right)]]", "M[tail=>N[(9,z)]]"],
    ),
    W236PCase.new(
      "variant_nested", variant_nested, variant_values,
      ["V0(N[(1,a),(2,long)])", "V1(v)", "VNULL", "V0(N[(255,x)])", "V1(much-longer)", "V0(N[(0,left),(17,r),(42,longer-right)])"],
    ),
  ] of W236PCase
end

private def w236p_signature(value : CrystalClick::BinaryValue) : String
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_NESTED
    records = (0...value.element_count).map do |index|
      row = value.element_at(index)
      "(#{row.child_at(0).byte_at(0)},#{row.child_at(1).as_string})"
    end
    "N[#{records.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    items = (0...value.element_count).map { |index| w236p_signature(value.element_at(index)) }
    "A[#{items.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
    "T(#{w236p_signature(value.child_at(0))},#{w236p_signature(value.child_at(1))})"
  when CrystalClick::BinaryDataType::TAG_MAP
    entries = (0...(value.child_count // 2)).map do |index|
      "#{value.child_at(index * 2).as_string}=>#{w236p_signature(value.child_at(index * 2 + 1))}"
    end
    "M[#{entries.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_VARIANT
    if index = value.variant_index?
      "V#{index}(#{w236p_signature(value.variant_child?.not_nil!)})"
    else
      "VNULL"
    end
  when CrystalClick::BinaryDataType::TAG_STRING
    value.as_string
  when CrystalClick::BinaryDataType::TAG_UINT8
    "#{value.byte_at(0)}"
  else
    raise "unexpected W236 physical value type: #{value.type.name}"
  end
end

private def w236p_signatures(marks : Array(Array(CrystalClick::ObjectDocument))) : Array(String)
  values = [] of String
  marks.each do |mark|
    mark.each { |document| values << w236p_signature(document.value_for("q")) }
  end
  values
end

private def w236p_u64_values(bytes : Bytes) : Array(UInt64)
  unless bytes.size % 8 == 0
    raise "W236 expected a complete UInt64 lane"
  end
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w236p_mark_rows(bytes : Bytes) : Array(UInt64)
  record_size = CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  unless bytes.size > 0 && bytes.size % record_size == 0
    raise "W236 mark file has an invalid record grid"
  end
  Array(UInt64).new(bytes.size // record_size) do |record|
    offset = record * record_size + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w236p_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w236p_corrupt_mark_decompressed_offset!(part : String, physical : CrystalClick::BinaryBulkPhysicalPlan,
                                                    role : String, record : Int, value : UInt64) : Nil
  path = File.join(part, physical.marks_file_for(role, true))
  bytes = File.read(path).to_slice.dup
  offset = record * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 8
  offset.should be < bytes.size
  w236p_write_u64(bytes, offset, value)
  File.write(path, bytes)
end

private def w236p_corrupt_literal_frame_byte!(path : String, raw_offset : Int, value : UInt8) : Nil
  frame = File.read(path).to_slice.dup
  frame[16].should eq(CrystalClick::CompressedBlock::METHOD_LZ4)
  compressed_size = frame[17].to_u32 | (frame[18].to_u32 << 8) |
                    (frame[19].to_u32 << 16) | (frame[20].to_u32 << 24)
  raw_size = frame[21].to_u32 | (frame[22].to_u32 << 8) |
             (frame[23].to_u32 << 16) | (frame[24].to_u32 << 24)
  raw_offset.should be < raw_size
  compressed_size.to_i.should eq(frame.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  token = frame[cursor]
  literal_count = (token >> 4).to_i
  cursor += 1
  if literal_count == 15
    loop do
      extension = frame[cursor]
      cursor += 1
      literal_count += extension.to_i
      break if extension < 255
    end
  end
  literal_count.should eq(raw_size)
  frame[cursor + raw_offset] = value
  checksum = CrystalClick::CityHashV1.hash128(
    frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i],
  )
  w236p_write_u64(frame, 0, checksum[0])
  w236p_write_u64(frame, 8, checksum[1])
  File.write(path, frame)
end

private def w236p_write_part(part : String, fixture : W236PCase) : Nil
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "id",
    Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
    "j",
    fixture.schema,
    fixture.plan,
    fixture.granules,
    rows_per_mark: 2,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    frame_bytes: 64,
  ).should eq(part)
end

describe "W236 nominal Nested in declared Object JSON physical lanes" do
  it "writes and reads every source-backed direct and wrapped Nested path over parent marks" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    fixtures = w236p_cases
    parent = File.tempname("crystal-click-w236-object-nested-physical-")
    Dir.mkdir(parent)
    begin
      fixtures.each_with_index do |fixture, index|
        destination = File.join(parent, "case-#{index}")
        _ = fixture.granules # Materialize and validate explicit defaults for absent typed q paths.
        _ = fixture.schema.declaration
        w236p_write_part(destination, fixture)

        reader = CrystalClick::ObjectColumnReader.open(destination, "j", fixture.schema)
        reader.row_count.should eq(6_u64)
        reader.ordinary_profile.should eq(profile)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        object_physical = CrystalClick::ObjectDocumentPhysicalPlan.new("j", fixture.plan, profile)
        reader.physical_stream_names.should eq(object_physical.stream_names)
        object_physical.stream_names.each do |name|
          marks = File.read(File.join(destination, "#{CrystalClick::StreamName.hash(name)}.mrk2")).to_slice
          w236p_mark_rows(marks).should eq([2_u64, 2_u64, 2_u64, 0_u64])
        end

        full = CrystalClick::ObjectDocumentFileReader.read(
          destination, "j", fixture.schema.typed_paths,
          first_mark: 0, mark_count: 3, profile: profile, hashed: true,
        )
        w236p_signatures(full).should eq(fixture.expected)
        w236p_signatures(CrystalClick::ObjectDocumentFileReader.read(
          destination, "j", fixture.schema.typed_paths,
          first_mark: 1, mark_count: 1, profile: profile, hashed: true,
        )).should eq(fixture.expected[2, 2])
        CrystalClick::ObjectDocumentFileReader.read(
          destination, "j", fixture.schema.typed_paths,
          first_mark: 0, mark_count: 0, profile: profile, hashed: true,
        ).should be_empty
        CrystalClick::ObjectDocumentFileReader.read(
          destination, "j", fixture.schema.typed_paths,
          first_mark: 3, mark_count: 0, profile: profile, hashed: true,
        ).should be_empty

        w236p_signatures(reader.read_marks(0, 3)).should eq(fixture.expected)
        w236p_signatures(reader.read_marks(1, 1)).should eq(fixture.expected[2, 2])
        reader.read_marks(0, 0).should be_empty
        reader.read_marks(3, 0).should be_empty
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips all-empty direct Nested payload lanes across real marks and terminal EOF" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["n", "s"] of String,
    )
    empty_nested = -> { w236p_nested(nested, [] of Tuple(UInt8, String)) }
    expected = ["N[]", "N[]", "N[]", "N[]", "N[]", "N[]"] of String
    fixture = W236PCase.new(
      "all_empty_direct_nested",
      nested,
      [empty_nested.call, empty_nested.call, empty_nested.call,
       empty_nested.call, empty_nested.call, empty_nested.call] of CrystalClick::BinaryValue?,
      expected,
    )

    encoded = CrystalClick::ObjectDocumentCodec.encode(fixture.plan, fixture.granules, profile: profile)
    typed = encoded.typed_for("q")
    typed.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 32_u64, 48_u64])
    w236p_u64_values(typed.stream("root.sizes").bytes).should eq(
      [0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64],
    )
    payload_roles = [
      "root.elements.field.0.data",
      "root.elements.field.1.string_sizes",
      "root.elements.field.1.data",
    ] of String
    payload_roles.each do |role|
      typed.stream(role).bytes.should be_empty
      typed.stream(role).offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])
    end

    parent = File.tempname("crystal-click-w236-empty-nested-physical-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "all-empty")
      w236p_write_part(destination, fixture)
      reader = CrystalClick::ObjectColumnReader.open(destination, "j", fixture.schema)
      reader.row_count.should eq(6_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])

      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("j", fixture.plan, profile).typed("q")
      payload_roles.each do |role|
        File.size(File.join(destination, physical.data_file_for(role, true))).should eq(0_i64)
        marks = File.read(File.join(destination, physical.marks_file_for(role, true))).to_slice
        w236p_u64_values(marks).should eq(
          [0_u64, 0_u64, 2_u64, 0_u64, 0_u64, 2_u64,
           0_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64],
        )
      end

      file_full = CrystalClick::ObjectDocumentFileReader.read(
        destination, "j", fixture.schema.typed_paths,
        first_mark: 0, mark_count: 3, profile: profile, hashed: true,
      )
      file_middle = CrystalClick::ObjectDocumentFileReader.read(
        destination, "j", fixture.schema.typed_paths,
        first_mark: 1, mark_count: 1, profile: profile, hashed: true,
      )
      file_zero = CrystalClick::ObjectDocumentFileReader.read(
        destination, "j", fixture.schema.typed_paths,
        first_mark: 0, mark_count: 0, profile: profile, hashed: true,
      )
      file_eof = CrystalClick::ObjectDocumentFileReader.read(
        destination, "j", fixture.schema.typed_paths,
        first_mark: 3, mark_count: 0, profile: profile, hashed: true,
      )
      w236p_signatures(file_full).should eq(expected)
      w236p_signatures(file_middle).should eq(expected[2, 2])
      file_zero.should be_empty
      file_eof.should be_empty

      w236p_signatures(reader.read_marks(0, 3)).should eq(expected)
      w236p_signatures(reader.read_marks(1, 1)).should eq(expected[2, 2])
      reader.read_marks(0, 0).should be_empty
      reader.read_marks(3, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps logical Nested element counts and String sizes distinct from parent row marks" do
    fixture = w236p_cases.find { |candidate| candidate.id == "direct_nested" }.not_nil!
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    streams = CrystalClick::ObjectDocumentCodec.encode(fixture.plan, fixture.granules, profile: profile)
    typed = streams.typed_for("q")
    typed.roles.should eq(CrystalClick::BinaryBulkTypePlan.new(fixture.type, profile).roles)

    typed.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 32_u64, 48_u64])
    w236p_u64_values(typed.stream("root.sizes").bytes).should eq([2_u64, 0_u64, 0_u64, 1_u64, 3_u64, 0_u64])
    typed.stream("root.elements.field.1.string_sizes").offsets.should eq([0_u64, 16_u64, 24_u64, 48_u64])
    w236p_u64_values(typed.stream("root.elements.field.1.string_sizes").bytes).should eq(
      [1_u64, 4_u64, 1_u64, 4_u64, 1_u64, 12_u64],
    )
    streams.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
    # Physical marks still index parent documents; the Nested sizes lane and
    # String-size lane carry the independent flattened child and byte counts.
  end

  it "uses one consumptive codec budget for statistics and value encoding" do
    fixture = w236p_cases.find { |candidate| candidate.id == "direct_nested" }.not_nil!
    roomy = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64, max_nodes: 4096, max_elements: 1_000_000, max_bytes: 1_048_576,
    )
    statistics_budget = CrystalClick::BinaryCodecBudget.new(roomy, true)
    recomputed = CrystalClick::ObjectDocumentStatistics.recompute_with_budget(
      fixture.plan, fixture.granules, statistics_budget,
    )
    statistics_nodes = statistics_budget.node_count
    CrystalClick::ObjectDocumentCodec.encode_with_budget(
      recomputed,
      fixture.granules,
      CrystalClick::BinaryCodecBudget.new(roomy, true),
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    encoding_budget = CrystalClick::BinaryCodecBudget.new(roomy, true)
    CrystalClick::ObjectDocumentCodec.encode_with_budget(
      recomputed,
      fixture.granules,
      encoding_budget,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    encoding_nodes = encoding_budget.node_count
    statistics_nodes.should be > 0
    encoding_nodes.should be > 0

    max_individual = Math.max(statistics_nodes, encoding_nodes)
    (statistics_nodes + encoding_nodes).should be > max_individual
    shared_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: roomy.max_depth,
      max_nodes: max_individual,
      max_elements: roomy.max_elements,
      max_bytes: roomy.max_bytes,
    )
    shared_budget = CrystalClick::BinaryCodecBudget.new(shared_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      shared_plan = CrystalClick::ObjectDocumentStatistics.recompute_with_budget(
        fixture.plan, fixture.granules, shared_budget,
      )
      CrystalClick::ObjectDocumentCodec.encode_with_budget(
        shared_plan,
        fixture.granules,
        shared_budget,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      )
    end
  end

  it "checks selected row-shape failures and complete mark grids without claiming payload authentication" do
    fixture = w236p_cases.find { |candidate| candidate.id == "direct_nested" }.not_nil!
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    parent = File.tempname("crystal-click-w236-object-nested-corruption-")
    Dir.mkdir(parent)
    begin
      original = File.join(parent, "original")
      w236p_write_part(original, fixture)
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new("j", fixture.plan, profile).typed("q")

      # The one-frame raw root.sizes lane is changed at the first row of mark 2
      # (Nested size 3 -> 4) while retaining a valid LZ4 frame checksum. Reading
      # mark 0 ignores that unselected semantic value; selecting mark 2 must
      # reject the count schedule because only three tuple records remain.
      shape_part = File.join(parent, "late-row-shape")
      FileUtils.cp_r(original, shape_part)
      size_lane = File.join(shape_part, physical.data_file_for("root.sizes", true))
      w236p_corrupt_literal_frame_byte!(size_lane, 32, 4_u8)
      w236p_signatures(CrystalClick::ObjectDocumentFileReader.read(
        shape_part, "j", fixture.schema.typed_paths,
        first_mark: 0, mark_count: 1, profile: profile, hashed: true,
      )).should eq(fixture.expected[0, 2])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          shape_part, "j", fixture.schema.typed_paths,
          first_mark: 2, mark_count: 1, profile: profile, hashed: true,
        )
      end

      # Mark-grid metadata is inspected for all marks, even when the damaged
      # record belongs to a mark outside the selected logical row window.
      selected_grid = File.join(parent, "selected-grid-offset")
      FileUtils.cp_r(original, selected_grid)
      w236p_corrupt_mark_decompressed_offset!(selected_grid, physical, "root.sizes", 1, UInt64::MAX)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          selected_grid, "j", fixture.schema.typed_paths,
          first_mark: 1, mark_count: 1, profile: profile, hashed: true,
        )
      end

      unselected_grid = File.join(parent, "unselected-grid-offset")
      FileUtils.cp_r(original, unselected_grid)
      w236p_corrupt_mark_decompressed_offset!(unselected_grid, physical, "root.sizes", 2, UInt64::MAX)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentFileReader.read(
          unselected_grid, "j", fixture.schema.typed_paths,
          first_mark: 0, mark_count: 1, profile: profile, hashed: true,
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
