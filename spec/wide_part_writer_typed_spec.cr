require "./spec_helper"

private def writer_typed_bits(value : T) : UInt64 forall T
  {% if T == UInt8 %}
    value.to_u64
  {% elsif T == UInt16 %}
    value.to_u64
  {% elsif T == UInt32 %}
    value.to_u64
  {% elsif T == UInt64 %}
    value
  {% elsif T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == Int32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Int64 %}
    value.unsafe_as(UInt64)
  {% elsif T == Float32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Float64 %}
    value.unsafe_as(UInt64)
  {% else %}
    raise "unsupported test numeric type"
  {% end %}
end

private def writer_typed_width(type : T.class) : Int32 forall T
  {% if T == UInt8 || T == Int8 %}
    1
  {% elsif T == UInt16 || T == Int16 %}
    2
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    4
  {% else %}
    8
  {% end %}
end

private def append_writer_typed_bytes(bytes : Array(UInt8), value : T) : Nil forall T
  bits = writer_typed_bits(value)
  writer_typed_width(T).times do |index|
    bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def writer_typed_bytes(values : Array(T)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each { |value| append_writer_typed_bytes(bytes, value) }
  bytes
end

private def writer_nullable_typed_bytes(values : Array(T?)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |value|
    if value.nil?
      writer_typed_width(T).times { bytes << 0_u8 }
    else
      append_writer_typed_bytes(bytes, value)
    end
  end
  bytes
end

private def writer_mark_rows(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid test mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_mark_compressed_offsets(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid test mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def assert_writer_numeric_payload(part : CrystalClick::WidePart, values : Array(T)) : Nil forall T
  expected_type = CrystalClick::WidePart.numeric_type_name(T)
  part.column_type.should eq(expected_type)
  observed = part.read_numeric_mark_range("value", 0, part.mark_count, T)
  {% if T == Float32 %}
    observed.map { |value| value.unsafe_as(UInt32) }.should eq(values.map { |value| value.unsafe_as(UInt32) })
  {% elsif T == Float64 %}
    observed.map { |value| value.unsafe_as(UInt64) }.should eq(values.map { |value| value.unsafe_as(UInt64) })
  {% else %}
    observed.should eq(values)
  {% end %}
end

private def assert_writer_nullable_numeric_payload(part : CrystalClick::WidePart, values : Array(T?)) : Nil forall T
  expected_type = "Nullable(#{CrystalClick::WidePart.numeric_type_name(T)})"
  part.column_type.should eq(expected_type)
  observed = part.read_nullable_numeric_mark_range("value", 0, part.mark_count, T)
  {% if T == Float32 %}
    observed.map { |value| value.try(&.unsafe_as(UInt32)) }.should eq(values.map { |value| value.try(&.unsafe_as(UInt32)) })
  {% elsif T == Float64 %}
    observed.map { |value| value.try(&.unsafe_as(UInt64)) }.should eq(values.map { |value| value.try(&.unsafe_as(UInt64)) })
  {% else %}
    observed.should eq(values)
  {% end %}
end

private def write_writer_numeric_case(values : Array(T), label : String) : Nil forall T
  parent = File.tempname("crystal-click-wide-writer-typed-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_typed_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "value",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    part = CrystalClick::WidePart.open_typed(destination, "value")
    part.row_count.should eq(5_u64)
    part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    assert_writer_numeric_payload(part, values)
    part.read_numeric_mark_range("value", 1, 1, T).size.should eq(2)

    data_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(writer_typed_bytes(values))
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def write_writer_nullable_numeric_case(values : Array(T?), label : String) : Nil forall T
  parent = File.tempname("crystal-click-wide-writer-typed-nullable-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_typed_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "value",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    part = CrystalClick::WidePart.open_typed(destination, "value")
    part.row_count.should eq(5_u64)
    part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    assert_writer_nullable_numeric_payload(part, values)

    null_path = File.join(destination, "#{CrystalClick::StreamName.hash("value.null")}.bin")
    null_bytes = CrystalClick::CompressedBlock.decode_all(File.read(null_path).to_slice).to_a
    null_bytes.should eq(values.map { |value| value.nil? ? 1_u8 : 0_u8 })

    data_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(writer_nullable_typed_bytes(values))
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def write_writer_string_case(values : Array(String), label : String) : Nil
  parent = File.tempname("crystal-click-wide-writer-typed-string-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_typed_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "value",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    part = CrystalClick::WidePart.open_typed(destination, "value")
    part.column_type.should eq("String")
    part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    part.read_string_mark_range("value", 0, part.mark_count).should eq(values)
    part.read_string_mark_range("value", 1, 1).should eq(values[2, 2])

    data_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
    if values.all?(&.empty?)
      File.size(data_path).should eq(0_i64)
    else
      CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(values.join.to_slice.to_a)
    end

    size_path = File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.bin")
    size_bytes = CrystalClick::CompressedBlock.decode_all(File.read(size_path).to_slice).to_a
    decoded_sizes = values.map { |value| value.bytesize.to_u64 }
    size_bytes.should eq(writer_typed_bytes(decoded_sizes))
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def write_writer_nullable_string_case(values : Array(String?), label : String) : Nil
  parent = File.tempname("crystal-click-wide-writer-typed-nullable-string-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_typed_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "value",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    part = CrystalClick::WidePart.open_typed(destination, "value")
    part.column_type.should eq("Nullable(String)")
    part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    part.read_nullable_string_mark_range("value", 0, part.mark_count).should eq(values)
    part.read_nullable_string_mark_range("value", 1, 1).should eq(values[2, 2])

    null_path = File.join(destination, "#{CrystalClick::StreamName.hash("value.null")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(null_path).to_slice).to_a.should eq(values.map { |value| value.nil? ? 1_u8 : 0_u8 })

    size_path = File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.bin")
    size_bytes = CrystalClick::CompressedBlock.decode_all(File.read(size_path).to_slice).to_a
    decoded_sizes = values.map { |value| value.nil? ? 0_u64 : value.bytesize.to_u64 }
    size_bytes.should eq(writer_typed_bytes(decoded_sizes))

    data_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
    if values.all?(&.nil?)
      File.size(data_path).should eq(0_i64)
    else
      expected_nested = values.compact.join.to_slice.to_a
      CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(expected_nested)
    end

    substreams = {"value.null" => writer_mark_rows(destination, "value.null"), "value.size" => writer_mark_rows(destination, "value.size"), "value" => writer_mark_rows(destination, "value")}
    substreams.each_value { |rows| rows.should eq([2_u64, 2_u64, 1_u64, 0_u64]) }
    {"value.null", "value.size", "value"}.each do |stream|
      data_path = File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")
      offsets = writer_mark_compressed_offsets(destination, stream)
      offsets.first.should eq(0_u64)
      offsets.each_cons(2) { |pair| pair[1].should be >= pair[0] }
      offsets.last.should eq(File.size(data_path).to_u64)
    end
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePartWriter do
  it "writes the exact UInt8 payload type through the typed entry point" do
    parent = File.tempname("crystal-click-wide-writer-typed-red")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    values = [0_u8, UInt8::MAX]

    begin
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("UInt8")
      part.read_numeric_mark_range("value", 0, part.mark_count, UInt8).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves exact scalar values and little-endian bytes for every reader numeric type" do
    write_writer_numeric_case([0_u8, 1_u8, 127_u8, 128_u8, UInt8::MAX], "u8")
    write_writer_numeric_case([0_u16, 1_u16, 0x7fff_u16, 0x8000_u16, UInt16::MAX], "u16")
    write_writer_numeric_case([0_u32, 1_u32, 0x7fff_ffff_u32, 0x8000_0000_u32, UInt32::MAX], "u32")
    write_writer_numeric_case([0_u64, 1_u64, 0x7fff_ffff_ffff_ffff_u64, 0x8000_0000_0000_0000_u64, UInt64::MAX], "u64")
    write_writer_numeric_case([Int8::MIN, -1_i8, 0_i8, 127_i8, 1_i8], "i8")
    write_writer_numeric_case([Int16::MIN, -1_i16, 0_i16, 1_i16, Int16::MAX], "i16")
    write_writer_numeric_case([Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX], "i32")
    write_writer_numeric_case([Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX], "i64")
    write_writer_numeric_case([
      0x0000_0000_u32.unsafe_as(Float32),
      0x8000_0000_u32.unsafe_as(Float32),
      0x3f80_0000_u32.unsafe_as(Float32),
      0x7fc1_2345_u32.unsafe_as(Float32),
      0xff80_0000_u32.unsafe_as(Float32),
    ], "f32")
    write_writer_numeric_case([
      0x0000_0000_0000_0000_u64.unsafe_as(Float64),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64),
      0x3ff8_0000_0000_0000_u64.unsafe_as(Float64),
      0x7ff8_0000_0000_1234_u64.unsafe_as(Float64),
      0xfff0_0000_0000_0000_u64.unsafe_as(Float64),
    ], "f64")
  end

  it "preserves nullable numeric nulls, defaults, edge values, and zero nested placeholders" do
    write_writer_nullable_numeric_case([nil, 0_u8.as(UInt8?), UInt8::MAX.as(UInt8?), nil, 1_u8.as(UInt8?)], "u8")
    write_writer_nullable_numeric_case([nil, 0_u16.as(UInt16?), UInt16::MAX.as(UInt16?), nil, 1_u16.as(UInt16?)], "u16")
    write_writer_nullable_numeric_case([nil, 0_u32.as(UInt32?), UInt32::MAX.as(UInt32?), nil, 1_u32.as(UInt32?)], "u32")
    write_writer_nullable_numeric_case([nil, 0_u64.as(UInt64?), UInt64::MAX.as(UInt64?), nil, 1_u64.as(UInt64?)], "u64")
    write_writer_nullable_numeric_case([nil, 0_i8.as(Int8?), Int8::MIN.as(Int8?), nil, Int8::MAX.as(Int8?)], "i8")
    write_writer_nullable_numeric_case([nil, 0_i16.as(Int16?), Int16::MIN.as(Int16?), nil, Int16::MAX.as(Int16?)], "i16")
    write_writer_nullable_numeric_case([nil, 0_i32.as(Int32?), Int32::MIN.as(Int32?), nil, Int32::MAX.as(Int32?)], "i32")
    write_writer_nullable_numeric_case([nil, 0_i64.as(Int64?), Int64::MIN.as(Int64?), nil, Int64::MAX.as(Int64?)], "i64")
    write_writer_nullable_numeric_case([
      nil,
      0x0000_0000_u32.unsafe_as(Float32).as(Float32?),
      0x8000_0000_u32.unsafe_as(Float32).as(Float32?),
      nil,
      0x7fc1_2345_u32.unsafe_as(Float32).as(Float32?),
    ], "f32")
    write_writer_nullable_numeric_case([
      nil,
      0x0000_0000_0000_0000_u64.unsafe_as(Float64).as(Float64?),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64).as(Float64?),
      nil,
      0x7ff8_0000_0000_1234_u64.unsafe_as(Float64).as(Float64?),
    ], "f64")

    write_writer_nullable_numeric_case(Array(UInt8?).new(5, nil), "u8-all-null")
    write_writer_nullable_numeric_case(Array(UInt16?).new(5, nil), "u16-all-null")
    write_writer_nullable_numeric_case(Array(UInt32?).new(5, nil), "u32-all-null")
    write_writer_nullable_numeric_case(Array(UInt64?).new(5, nil), "u64-all-null")
    write_writer_nullable_numeric_case(Array(Int8?).new(5, nil), "i8-all-null")
    write_writer_nullable_numeric_case(Array(Int16?).new(5, nil), "i16-all-null")
    write_writer_nullable_numeric_case(Array(Int32?).new(5, nil), "i32-all-null")
    write_writer_nullable_numeric_case(Array(Int64?).new(5, nil), "i64-all-null")
    write_writer_nullable_numeric_case(Array(Float32?).new(5, nil), "f32-all-null")
    write_writer_nullable_numeric_case(Array(Float64?).new(5, nil), "f64-all-null")
  end

  it "writes regular String and Nullable(String) with exact empty, binary, and UTF-8 values" do
    write_writer_string_case(["", "alpha", "a\0b", "é", "tail"], "mixed")
    write_writer_string_case(["", "", "", "", ""], "all-empty")
    write_writer_nullable_string_case([nil, "".as(String?), "x\0y".as(String?), nil, "é".as(String?)], "mixed")
    write_writer_nullable_string_case(Array(String?).new(5, nil), "all-null")

    # This four-row sentinel keeps the nullable null-vs-empty boundary explicit.
    parent = File.tempname("crystal-click-wide-writer-typed-nullable-string-boundary")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    values = [nil, "".as(String?), "x\0y".as(String?), nil]
    begin
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )
      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("Nullable(String)")
      part.mark_row_counts.should eq([2_u64, 2_u64])
      part.read_nullable_string_mark_range("value", 0, 2).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid names, keys, lengths, empty parts, and mark sizes without publication" do
    invalid_calls = [
      {"../pk", "value", [1_u64, 2_u64], [3_u8, 4_u8], 1},
      {"pk", "../value", [1_u64, 2_u64], [3_u8, 4_u8], 1},
      {"same", "same", [1_u64, 2_u64], [3_u8, 4_u8], 1},
      {"pk", "value", [2_u64, 1_u64], [3_u8, 4_u8], 1},
      {"pk", "value", [1_u64, 2_u64], [3_u8], 1},
      {"pk", "value", [] of UInt64, [] of UInt8, 1},
      {"pk", "value", [1_u64, 2_u64], [3_u8, 4_u8], 0},
      {"pk", "value", [1_u64, 2_u64], [3_u8, 4_u8], 65_537},
    ]

    invalid_calls.each do |input|
      parent = File.tempname("crystal-click-wide-writer-typed-invalid")
      Dir.mkdir(parent)
      destination = File.join(parent, "part")
      begin
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            destination,
            input[0],
            input[2].to_unsafe.to_slice(input[2].size),
            input[1],
            input[3].to_unsafe.to_slice(input[3].size),
            rows_per_mark: input[4]
          )
        end
        Dir.children(parent).should eq([] of String)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects a typed String granule beyond the reader frame limit before publication" do
    parent = File.tempname("crystal-click-wide-writer-typed-string-oversized")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    oversized = String.new(Bytes.new(CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES + 1, 0_u8))

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          [oversized].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an oversized Nullable(String) payload before publication" do
    parent = File.tempname("crystal-click-wide-writer-typed-nullable-string-oversized")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    oversized = String.new(Bytes.new(CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES + 1, 0_u8))
    values = Array(String?).new(1, oversized)

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
