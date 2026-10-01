require "./spec_helper"

private def w106_nullable_enum_column(
  name : String,
  type_name : String,
  values : Array(Int8),
  null_bytes : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(#{type_name})") ||
              raise "invalid W106 Nullable Enum type"
  null_map = CrystalClick::ScalarNullMap.new(
    null_bytes.to_unsafe.to_slice(null_bytes.size), values.size.to_u64
  )
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, null_map)
end

private def w106_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w106_mark_rows(part : String, stream : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def w106_payload_record(part : String) : JSON::Any
  JSON.parse(File.read(File.join(part, "serialization.json")))["columns"].as_a.find do |record|
    record["name"].as_s == "payload"
  end.not_nil!
end

describe CrystalClick::WidePartWriter do
  it "writes recursive Tuple paths and computes each node's default count from row correlations" do
    parent = File.tempname("crystal-click-wide-writer-nested-tuple-w106")
    Dir.mkdir(parent)
    type_name = "Tuple(left Tuple(a UInt8, b UInt8), right Tuple(branch Tuple(code Nullable(Enum8('zero' = 0, 'plus' = 4)), text String), tail UInt8))"
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    nulls = [1_u8, 1_u8, 0_u8, 0_u8]
    columns_a = [
      CrystalClick::WideTupleLeafColumn.new("left.a", [0_u8, 0_u8, 9_u8, 9_u8] of UInt8),
      CrystalClick::WideTupleLeafColumn.new("left.b", [9_u8, 9_u8, 0_u8, 0_u8] of UInt8),
      w106_nullable_enum_column("right.branch.code", "Enum8('zero' = 0, 'plus' = 4)", [127_i8, 126_i8, 0_i8, 4_i8], nulls),
      CrystalClick::WideTupleLeafColumn.new("right.branch.text", ["", "", "note", "note"] of String),
      CrystalClick::WideTupleLeafColumn.new("right.tail", [0_u8, 0_u8, 9_u8, 9_u8] of UInt8),
    ] of CrystalClick::WideTupleLeafColumn
    # Every terminal leaf has exactly two default rows in both fixtures. Only
    # the rowwise correlation between left.a and left.b changes.
    columns_b = columns_a.dup
    columns_b[1] = CrystalClick::WideTupleLeafColumn.new(
      "left.b", [0_u8, 0_u8, 9_u8, 9_u8] of UInt8
    )
    first_part = File.join(parent, "anti-correlated")
    second_part = File.join(parent, "correlated")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        first_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns_a, 3
      ).should eq(first_part)
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        second_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns_b, 3
      ).should eq(second_part)

      expected_streams = [
        "payload%2Eleft%2Ea",
        "payload%2Eleft%2Eb",
        "payload%2Eright%2Ebranch%2Ecode.null",
        "payload%2Eright%2Ebranch%2Ecode",
        "payload%2Eright%2Ebranch%2Etext.size",
        "payload%2Eright%2Ebranch%2Etext",
        "payload%2Eright%2Etail",
      ]
      File.read(File.join(first_part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n" +
        "1 substreams for column `pk`:\n\tpk\n" +
        "7 substreams for column `payload`:\n" +
        expected_streams.map { |stream| "\t#{stream}\n" }.join
      )
      w106_stream_bytes(first_part, "payload%2Eleft%2Ea").should eq([0_u8, 0_u8, 9_u8, 9_u8])
      w106_stream_bytes(first_part, "payload%2Eleft%2Eb").should eq([9_u8, 9_u8, 0_u8, 0_u8])
      w106_stream_bytes(first_part, "payload%2Eright%2Ebranch%2Ecode.null").should eq(nulls)
      # Invalid Enum codes in masked slots remain raw and are not used to
      # calculate Nullable defaults or reject the leaf.
      w106_stream_bytes(first_part, "payload%2Eright%2Ebranch%2Ecode").should eq([127_u8, 126_u8, 0_u8, 4_u8])
      w106_stream_bytes(first_part, "payload%2Eright%2Ebranch%2Etext.size").should eq([
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
        4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      ])
      w106_stream_bytes(first_part, "payload%2Eright%2Ebranch%2Etext").should eq("notenote".to_slice.to_a)
      w106_mark_rows(first_part, "payload%2Eright%2Ebranch%2Ecode.null").should eq([3_u64, 1_u64, 0_u64])
      w106_mark_rows(first_part, "payload%2Eright%2Ebranch%2Etext").should eq([3_u64, 1_u64, 0_u64])

      first_payload = w106_payload_record(first_part)
      second_payload = w106_payload_record(second_part)
      first_payload["num_defaults"].as_i.should eq(0)
      second_payload["num_defaults"].as_i.should eq(2)
      first_children = first_payload["subcolumns"].as_a
      second_children = second_payload["subcolumns"].as_a
      first_children.map { |node| node["num_defaults"].as_i }.should eq([0, 2])
      second_children.map { |node| node["num_defaults"].as_i }.should eq([2, 2])
      first_children[0]["subcolumns"].as_a.map { |node| node["num_defaults"].as_i }.should eq([2, 2])
      second_children[0]["subcolumns"].as_a.map { |node| node["num_defaults"].as_i }.should eq([2, 2])
      first_right_children = first_children[1]["subcolumns"].as_a
      second_right_children = second_children[1]["subcolumns"].as_a
      first_right_children.map { |node| node["num_defaults"].as_i }.should eq([2, 2])
      second_right_children.map { |node| node["num_defaults"].as_i }.should eq([2, 2])
      first_right_children[0]["subcolumns"].as_a.map { |node| node["num_defaults"].as_i }.should eq([2, 2])

      first = CrystalClick::WidePart.open_typed(first_part, "payload")
        .read_tuple_mark_range("payload", 0, 2)
      first.fields.map(&.name).should eq(columns_a.map(&.name))
      first.columns[2].null_map.not_nil!.bytes.should eq(nulls)
      first.columns[2].physical_values.as(Array(Int8)).should eq([127_i8, 126_i8, 0_i8, 4_i8])
      first.columns[3].physical_values.as(Array(String)).should eq(["", "", "note", "note"])

      copy = File.join(parent, "copy")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        copy, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, first.columns, 3
      ).should eq(copy)
      Dir.children(first_part).sort.should eq(Dir.children(copy).sort)
      Dir.children(first_part).each do |name|
        File.read(File.join(copy, name)).should eq(File.read(File.join(first_part, name)))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a mismatched nested logical leaf path before creating any stage or destination" do
    parent = File.tempname("crystal-click-wide-writer-nested-tuple-w106-preflight")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    type_name = "Tuple(left Tuple(value UInt64), right Tuple(value UInt64))"
    columns = [
      CrystalClick::WideTupleLeafColumn.new("left.value", [1_u64, 2_u64] of UInt64),
      CrystalClick::WideTupleLeafColumn.new("left.value", [3_u64, 4_u64] of UInt64),
    ] of CrystalClick::WideTupleLeafColumn

    begin
      before = Dir.children(parent).sort
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_tuple_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
        )
      end
      Dir.children(parent).sort.should eq(before)
      File.exists?(destination).should be_false
      File.symlink?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
