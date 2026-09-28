require "./spec_helper"

private def json_typed_general_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  File.read(path).to_slice
end

private def json_typed_general_decode(part : String, logical_name : String) : Array(UInt8)
  CrystalClick::CompressedBlock.decode_all(json_typed_general_stream(part, logical_name)).to_a
end

private def json_typed_general_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = (value >> (index * 8)).to_u8 }
end

private def json_typed_general_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index { |value, index| json_typed_general_write_u64(bytes, index * 8, value) }
  bytes.to_a
end

private def json_typed_general_i16_bytes(values : Array(Int16)) : Array(UInt8)
  values.flat_map do |value|
    bits = value.unsafe_as(UInt16)
    [(bits & 0xff_u16).to_u8, (bits >> 8).to_u8]
  end
end

private def json_typed_general_f32_bytes(values : Array(Float32)) : Array(UInt8)
  bytes = Bytes.new(values.size * 4)
  values.each_with_index do |value, index|
    bits = value.unsafe_as(UInt32)
    4.times { |offset| bytes[index * 4 + offset] = ((bits >> (offset * 8)) & 0xff_u32).to_u8 }
  end
  bytes.to_a
end

private def json_typed_general_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid test mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def json_typed_general_path(name : String, type_name : String, values : Array(T)) : CrystalClick::WidePartWriter::JSONTypedPathColumn forall T
  CrystalClick::WidePartWriter::JSONTypedPathColumn.new(name, type_name, values)
end

describe CrystalClick::WidePartWriter do
  it "writes mixed-width declared JSON typed paths with independent marks and normalized values" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-general")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64]
    int16_values = [-2_i16, 0_i16, 32_767_i16]
    float32_values = [1.5_f32, -0.0_f32, 3.25_f32]
    string_values = ["x\0y", "", "last"]
    paths = [
      json_typed_general_path("a", "Int16", int16_values),
      json_typed_general_path("b", "Float32", float32_values),
      json_typed_general_path("c", "String", string_values),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        paths,
        rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`j` JSON(a Int16, b Float32, c String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n8 substreams for column `j`:\n" +
        "\tj.object_structure\n\tj.a\n\tj.b\n\tj.c.size\n\tj.c\n" +
        "\tj.object_shared_data.0.size0\n\tj.object_shared_data.0%2Epaths\n\tj.object_shared_data.0%2Evalues\n"
      )
      File.read(File.join(destination, "count.txt")).should eq("3")

      json_typed_general_decode(destination, "j.a").should eq(json_typed_general_i16_bytes(int16_values))
      json_typed_general_decode(destination, "j.b").should eq(json_typed_general_f32_bytes(float32_values))
      json_typed_general_decode(destination, "j.c.size").should eq(
        json_typed_general_u64_bytes(string_values.map { |value| value.bytesize.to_u64 })
      )
      json_typed_general_decode(destination, "j.c").should eq(string_values.join.to_slice.to_a)
      json_typed_general_decode(destination, "j.object_shared_data.0.size0").should eq(
        json_typed_general_u64_bytes([0_u64, 0_u64, 0_u64])
      )
      File.size(File.join(destination, "#{CrystalClick::StreamName.hash("j.object_shared_data.0%2Epaths")}.bin")).should eq(0_i64)
      File.size(File.join(destination, "#{CrystalClick::StreamName.hash("j.object_shared_data.0%2Evalues")}.bin")).should eq(0_i64)

      ["pk", "j.a", "j.b", "j.c.size", "j.c", "j.object_structure", "j.object_shared_data.0.size0"].each do |name|
        json_typed_general_mark_rows(destination, name).should eq([2_u64, 1_u64, 0_u64])
      end
      ["j.object_shared_data.0%2Epaths", "j.object_shared_data.0%2Evalues"].each do |name|
        json_typed_general_mark_rows(destination, name).should eq([2_u64, 1_u64, 0_u64])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "emits canonical sorted JSON metadata and physical typed paths" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-order")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    paths = [
      json_typed_general_path("z", "String", ["tail", ""]),
      json_typed_general_path("a", "Int16", [-4_i16, 7_i16]),
      json_typed_general_path("m", "Float32", [2_f32, -1_f32]),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        paths,
        rows_per_mark: 1
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`j` JSON(a Int16, m Float32, z String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n8 substreams for column `j`:\n" +
        "\tj.object_structure\n\tj.a\n\tj.m\n\tj.z.size\n\tj.z\n" +
        "\tj.object_shared_data.0.size0\n\tj.object_shared_data.0%2Epaths\n\tj.object_shared_data.0%2Evalues\n"
      )
      json_typed_general_decode(destination, "j.a").should eq(json_typed_general_i16_bytes([-4_i16, 7_i16]))
      json_typed_general_decode(destination, "j.m").should eq(json_typed_general_f32_bytes([2_f32, -1_f32]))
      json_typed_general_decode(destination, "j.z.size").should eq(json_typed_general_u64_bytes([4_u64, 0_u64]))
      json_typed_general_decode(destination, "j.z").should eq("tail".to_slice.to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves non-finite Float32 payload bits" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-float-bits")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    float_values = [Float32::INFINITY, 0x7fc0_0001_u32.unsafe_as(Float32), -Float32::INFINITY]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        [json_typed_general_path("f", "Float32", float_values)],
        rows_per_mark: 2
      )

      json_typed_general_decode(destination, "j.f").should eq(json_typed_general_f32_bytes(float_values))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts an exact-limit JSON metadata line that the reader can open" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-metadata-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    path_name = "b" + "x" * (CrystalClick::WidePart::MAX_METADATA_LINE_BYTES - 27)
    keys = [1_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        [
          json_typed_general_path("a", "Int16", [1_i16]),
          json_typed_general_path(path_name, "Int16", [2_i16]),
        ],
        rows_per_mark: 1
      )
      CrystalClick::WidePart.open(destination, "pk").read_uint64.should eq(keys)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid declarations, values, granules, and destination collisions before publication" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-general-invalid")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    valid_paths = [json_typed_general_path("a", "Int16", [3_i16, 4_i16])]

    begin
      invalid_cases = {
        "empty-paths"               => [] of CrystalClick::WidePartWriter::JSONTypedPathColumn,
        "duplicate-path"            => [json_typed_general_path("a", "Int16", [3_i16, 4_i16]), json_typed_general_path("a", "String", ["x", "y"])],
        "dotted-path"               => [json_typed_general_path("a.b", "Int16", [3_i16, 4_i16])],
        "reserved-object-structure" => [json_typed_general_path("object_structure", "Int16", [3_i16, 4_i16])],
        "wrong-declared-type"       => [json_typed_general_path("a", "Int32", [3_i16, 4_i16])],
        "type-alias"                => [json_typed_general_path("a", "Float", [3_i16, 4_i16])],
        "unequal-rows"              => [json_typed_general_path("a", "Int16", [3_i16])],
      }
      invalid_cases.each do |suffix, paths|
        destination = File.join(parent, suffix)
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "j",
            paths,
            rows_per_mark: 1
          )
        end
        File.exists?(destination).should be_false
      end

      unsorted = File.join(parent, "unsorted")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          unsorted,
          "pk",
          [2_u64, 1_u64].to_unsafe.to_slice(2),
          "j",
          valid_paths,
          rows_per_mark: 1
        )
      end
      File.exists?(unsorted).should be_false

      column_collision = File.join(parent, "column-collision")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          column_collision,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "pk",
          valid_paths,
          rows_per_mark: 1
        )
      end
      File.exists?(column_collision).should be_false

      path_stream_collision = File.join(parent, "path-stream-collision")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          path_stream_collision,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "j",
          [json_typed_general_path("object_structure", "Int16", [3_i16, 4_i16])],
          rows_per_mark: 1
        )
      end
      File.exists?(path_stream_collision).should be_false

      oversized = File.join(parent, "oversized-granule")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          oversized,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "j",
          valid_paths,
          rows_per_mark: CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1
        )
      end
      File.exists?(oversized).should be_false

      oversized_payload = File.join(parent, "oversized-string-payload")
      oversized_string = String.new(Bytes.new(CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES + 1, 0x61_u8))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          oversized_payload,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "j",
          [json_typed_general_path("s", "String", [oversized_string])],
          rows_per_mark: 1
        )
      end
      File.exists?(oversized_payload).should be_false

      metadata_boundary = File.join(parent, "metadata-line-boundary")
      boundary_path_name = "b" + "x" * (CrystalClick::WidePart::MAX_METADATA_LINE_BYTES - 26)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          metadata_boundary,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "j",
          [
            json_typed_general_path("a", "Int16", [1_i16]),
            json_typed_general_path(boundary_path_name, "Int16", [2_i16]),
          ],
          rows_per_mark: 1
        )
      end
      File.exists?(metadata_boundary).should be_false

      collision = File.join(parent, "collision")
      Dir.mkdir(collision)
      File.write(File.join(collision, "sentinel"), "preserve")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
          collision,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "j",
          valid_paths,
          rows_per_mark: 1
        )
      end
      File.read(File.join(collision, "sentinel")).should eq("preserve")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
