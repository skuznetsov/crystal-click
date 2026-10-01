require "./spec_helper"
require "file_utils"

private def w98_writer_bool_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w98_writer_bool_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w98_writer_bool_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w98_writer_bool_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w98_writer_bool_literal_frame(raw : Bytes) : Bytes
  raise "W98 writer mutation cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w98_writer_bool_write_u32(frame, header + 1, compressed_size.to_u32)
  w98_writer_bool_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w98_writer_bool_write_u64(frame, 0, checksum[0])
  w98_writer_bool_write_u64(frame, 8, checksum[1])
  frame
end

private def w98_writer_bool_refresh_checksums(part : String) : Nil
  checksums = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w98_writer_bool_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = checksums.entries[name]
    w98_writer_bool_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w98_writer_bool_write_varuint(payload, file_bytes.size.to_u64)
    w98_writer_bool_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = file_bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w98_writer_bool_write_varuint(payload, raw.size.to_u64)
      w98_writer_bool_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w98_writer_bool_literal_frame(payload.to_slice))
  end
end

private def w98_writer_bool_replace_stream_byte(part : String, stream : String, offset : Int, value : UInt8) : Nil
  stream_hash = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{stream_hash}.bin")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
  raise "W98 writer mutation offset is outside #{stream}" if offset < 0 || offset >= raw.size
  raw[offset] = value

  frame = w98_writer_bool_literal_frame(raw)
  File.write(data_path, frame)

  marks_path = File.join(part, "#{stream_hash}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W98 writer fixture expects one data mark and a sentinel" unless marks.size == 2 * mark_size
  w98_writer_bool_write_u64(marks, mark_size, frame.size.to_u64)
  File.write(marks_path, marks)
  w98_writer_bool_refresh_checksums(part)
end

module CrystalClick
  module WidePartWriter
    class TuplePartWriter
      def self.w98_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end
    end

    def self.w98_test_validate_root_bool_stage(
      stage : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Bool),
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_typed_numeric_part(stage, "pk", value_name, keys, values, "Bool", rows_per_mark)
    end

    def self.w98_test_validate_nullable_bool_stage(
      stage : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Bool?),
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_nullable_numeric_part(stage, "pk", value_name, keys, values, "Nullable(Bool)", rows_per_mark)
    end

    def self.w98_test_validate_array_bool_stage(
      stage : String,
      keys : Slice(UInt64),
      values : Slice(Array(Bool)),
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_bool_part(stage, "pk", "payload", keys, values, rows_per_mark)
    end

    def self.w98_test_validate_array_nullable_bool_stage(
      stage : String,
      keys : Slice(UInt64),
      values : Slice(Array(Bool?)),
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_array_nullable_bool_part(stage, "pk", "payload", keys, values, rows_per_mark)
    end

    def self.w98_test_validate_variant_bool_stage(
      stage : String,
      keys : Slice(UInt64),
      values : Slice(VariantBoolStringUInt64Value),
      rows_per_mark : Int32,
    ) : Nil
      validate_staged_variant_bool_string_uint64_part(stage, "pk", "payload", keys, values, rows_per_mark)
    end

    def self.w98_test_validate_array_map_bool_stage(
      stage : String,
      values : Slice(Array(Array(Tuple(UInt64, Bool)))),
      rows_per_mark : Int32,
    ) : Nil
      plan = ArrayMapNumericPhysicalPlan.build("payload", "UInt64", "Bool", false, numeric_width("Bool"))
      validate_staged_array_map_bool_leaf_streams(stage, values, rows_per_mark, plan)
    end

    def self.w98_test_validate_array_map_string_nullable_bool_stage(
      stage : String,
      values : Slice(Array(Array(Tuple(String, Bool?)))),
      rows_per_mark : Int32,
    ) : Nil
      plan = ArrayMapNumericPhysicalPlan.build("payload", "String", "Bool", true, numeric_width("Bool"))
      validate_staged_array_map_bool_leaf_streams(stage, values, rows_per_mark, plan)
    end

    def self.w98_test_array_map_bool_stream_name : String
      plan = ArrayMapNumericPhysicalPlan.build("payload", "UInt64", "Bool", false, numeric_width("Bool"))
      plan.streams.last.name
    end

    def self.w98_test_validate_tuple_stage(
      stage : String,
      keys : Array(UInt64),
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
    ) : Nil
      type_plan = WideTupleTypePlan.for_type(type_name) || raise "invalid W98 Tuple test type"
      leaf_buffers = Array(TupleLeafBuffers).new(columns.size) { |index| columns[index].physical_values }
      logical_streams = ["pk"] + type_plan.physical_streams("payload")
      mark_count = checked_mark_count(keys.size, rows_per_mark)
      input = TuplePartWriteInput.new(
        File.join(File.dirname(stage), "not-published"),
        File.dirname(stage),
        "pk",
        keys.dup,
        "payload",
        type_plan,
        leaf_buffers,
        Array(Array(UInt8)?).new(leaf_buffers.size, nil),
        logical_streams,
        Array(Int64).new(logical_streams.size, 0_i64),
        Array(UInt64).new(logical_streams.size, 0_u64),
        mark_count,
        rows_per_mark,
        File.read(File.join(stage, "columns.txt")),
        File.read(File.join(stage, "columns_substreams.txt")),
        File.read(File.join(stage, "serialization.json")),
      )
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) { column.string_values }
      )
      TuplePartWriter.w98_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

private def w98_writer_bool_with_parent(& : String ->)
  parent = File.tempname("crystal-click-w98-writer-bool-canonical")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W98 staged Bool canonical output guard" do
  it "rejects a checksummed Tuple Bool byte 2 even though the reader decodes it as true" do
    parent = File.tempname("crystal-click-w98-bool-canonical-tuple")
    Dir.mkdir(parent)
    canonical = File.join(parent, "canonical")
    mutated = File.join(parent, "mutated-stage")
    keys = [1_u64, 2_u64]
    type_name = "Tuple(flag Bool)"
    columns = [CrystalClick::WideTupleLeafColumn.new("flag", [false, true])] of CrystalClick::WideTupleLeafColumn

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        canonical, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, rows_per_mark: 2
      )

      canonical_reader = CrystalClick::WidePart.open_typed(canonical, "payload")
      canonical_data = canonical_reader.read_tuple_mark_range("payload", 0, 1)
      canonical_data.value_as("flag", 0, Bool).should be_false
      canonical_data.value_as("flag", 1, Bool).should be_true

      CrystalClick::WidePartWriter.w98_test_validate_tuple_stage(canonical, keys, type_name, columns, 2)

      FileUtils.cp_r(canonical, mutated)
      w98_writer_bool_replace_stream_byte(mutated, "payload%2Eflag", 1, 2_u8)

      mutated_reader = CrystalClick::WidePart.open_typed(mutated, "payload")
      mutated_data = mutated_reader.read_tuple_mark_range("payload", 0, 1)
      mutated_data.value_as("flag", 0, Bool).should be_false
      mutated_data.value_as("flag", 1, Bool).should be_true

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_tuple_stage(mutated, keys, type_name, columns, 2)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "W98 staged Bool guards for existing payload owners" do
  it "raw-checks root Bool and Nullable(Bool), including the hidden NULL child default" do
    w98_writer_bool_with_parent do |parent|
      keys = [1_u64, 2_u64]
      root_values = [false, true]
      root_part = File.join(parent, "root")
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        root_part, "pk", keys.to_unsafe.to_slice(2), "flag", root_values.to_unsafe.to_slice(2), 2
      )
      CrystalClick::WidePartWriter.w98_test_validate_root_bool_stage(
        root_part, "flag", keys.to_unsafe.to_slice(2), root_values.to_unsafe.to_slice(2), 2
      )

      root_mutated = File.join(parent, "root-mutated")
      FileUtils.cp_r(root_part, root_mutated)
      w98_writer_bool_replace_stream_byte(root_mutated, "flag", 1, 2_u8)
      CrystalClick::WidePart.open_typed(root_mutated, "flag")
        .read_bool_mark_range("flag", 0, 1).should eq([false, true])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_root_bool_stage(
          root_mutated, "flag", keys.to_unsafe.to_slice(2), root_values.to_unsafe.to_slice(2), 2
        )
      end

      nullable_values = [nil.as(Bool?), false.as(Bool?)]
      nullable_part = File.join(parent, "nullable")
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(2), "flag", nullable_values.to_unsafe.to_slice(2), 2
      )
      CrystalClick::WidePartWriter.w98_test_validate_nullable_bool_stage(
        nullable_part, "flag", keys.to_unsafe.to_slice(2), nullable_values.to_unsafe.to_slice(2), 2
      )
      CrystalClick::WidePart.open_typed(nullable_part, "flag")
        .read_nullable_bool_mark_range("flag", 0, 1).should eq([nil, false])

      nullable_mutated = File.join(parent, "nullable-mutated")
      FileUtils.cp_r(nullable_part, nullable_mutated)
      w98_writer_bool_replace_stream_byte(nullable_mutated, "flag", 1, 2_u8)
      CrystalClick::WidePart.open_typed(nullable_mutated, "flag")
        .read_nullable_bool_mark_range("flag", 0, 1).should eq([nil, true])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_nullable_bool_stage(
          nullable_mutated, "flag", keys.to_unsafe.to_slice(2), nullable_values.to_unsafe.to_slice(2), 2
        )
      end

      nullable_hidden_mutated = File.join(parent, "nullable-hidden-mutated")
      FileUtils.cp_r(nullable_part, nullable_hidden_mutated)
      w98_writer_bool_replace_stream_byte(nullable_hidden_mutated, "flag", 0, 2_u8)
      CrystalClick::WidePart.open_typed(nullable_hidden_mutated, "flag")
        .read_nullable_bool_mark_range("flag", 0, 1).should eq([nil, false])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_nullable_bool_stage(
          nullable_hidden_mutated, "flag", keys.to_unsafe.to_slice(2), nullable_values.to_unsafe.to_slice(2), 2
        )
      end
    end
  end

  it "raw-checks Array(Bool) and keeps an empty nested child stream canonical" do
    w98_writer_bool_with_parent do |parent|
      keys = [1_u64]
      values = [[false, true]]
      part = File.join(parent, "array")
      CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
        part, "pk", keys.to_unsafe.to_slice(1), "payload", values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_bool_stage(
        part, keys.to_unsafe.to_slice(1), values.to_unsafe.to_slice(1), 1
      )

      mutated = File.join(parent, "array-mutated")
      FileUtils.cp_r(part, mutated)
      w98_writer_bool_replace_stream_byte(mutated, "payload", 1, 2_u8)
      CrystalClick::WidePart.open_typed(mutated, "payload")
        .read_array_bool_mark_range("payload", 0, 1).should eq([[false, true]])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_array_bool_stage(
          mutated, keys.to_unsafe.to_slice(1), values.to_unsafe.to_slice(1), 1
        )
      end

      empty_values = [[] of Bool]
      empty_part = File.join(parent, "array-empty")
      CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
        empty_part, "pk", keys.to_unsafe.to_slice(1), "payload", empty_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_bool_stage(
        empty_part, keys.to_unsafe.to_slice(1), empty_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePart.open_typed(empty_part, "payload")
        .read_array_bool_mark_range("payload", 0, 1).should eq([[] of Bool])
    end
  end

  it "raw-checks Array(Nullable(Bool)) and requires zero beneath NULL" do
    w98_writer_bool_with_parent do |parent|
      keys = [1_u64]
      values = [[nil.as(Bool?), false.as(Bool?), true.as(Bool?)]]
      part = File.join(parent, "array-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        part, "pk", keys.to_unsafe.to_slice(1), "payload", values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_nullable_bool_stage(
        part, keys.to_unsafe.to_slice(1), values.to_unsafe.to_slice(1), 1
      )

      mutated = File.join(parent, "array-nullable-mutated")
      FileUtils.cp_r(part, mutated)
      w98_writer_bool_replace_stream_byte(mutated, "payload", 2, 2_u8)
      CrystalClick::WidePart.open_typed(mutated, "payload")
        .read_array_nullable_bool_mark_range("payload", 0, 1).should eq([[nil, false, true]])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_array_nullable_bool_stage(
          mutated, keys.to_unsafe.to_slice(1), values.to_unsafe.to_slice(1), 1
        )
      end

      null_values = [[nil.as(Bool?)]]
      null_part = File.join(parent, "array-null-only")
      CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
        null_part, "pk", keys.to_unsafe.to_slice(1), "payload", null_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_nullable_bool_stage(
        null_part, keys.to_unsafe.to_slice(1), null_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePart.open_typed(null_part, "payload")
        .read_array_nullable_bool_mark_range("payload", 0, 1).should eq([[nil]])
    end
  end

  it "raw-checks sparse Variant Bool bytes without skipping false and accepts an absent Bool child" do
    w98_writer_bool_with_parent do |parent|
      keys = [1_u64, 2_u64]
      values = [false, true] of CrystalClick::VariantBoolStringUInt64Value
      part = File.join(parent, "variant")
      CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
        part, "pk", keys.to_unsafe.to_slice(2), "payload", values.to_unsafe.to_slice(2), 2
      )
      CrystalClick::WidePartWriter.w98_test_validate_variant_bool_stage(
        part, keys.to_unsafe.to_slice(2), values.to_unsafe.to_slice(2), 2
      )

      mutated = File.join(parent, "variant-mutated")
      FileUtils.cp_r(part, mutated)
      w98_writer_bool_replace_stream_byte(mutated, "payload.Bool", 1, 2_u8)
      CrystalClick::WidePart.open_typed(mutated, "payload")
        .read_variant_bool_string_uint64_mark_range("payload", 0, 1)
        .should eq([false, true] of CrystalClick::VariantBoolStringUInt64Value)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_variant_bool_stage(
          mutated, keys.to_unsafe.to_slice(2), values.to_unsafe.to_slice(2), 2
        )
      end

      absent_values = ["no Bool child"] of CrystalClick::VariantBoolStringUInt64Value
      absent_part = File.join(parent, "variant-absent-bool")
      CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
        absent_part, "pk", [3_u64].to_unsafe.to_slice(1), "payload", absent_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_variant_bool_stage(
        absent_part, [3_u64].to_unsafe.to_slice(1), absent_values.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePart.open_typed(absent_part, "payload")
        .read_variant_bool_string_uint64_mark_range("payload", 0, 1).should eq(absent_values)
    end
  end

  it "retains Array(Map) raw validation for visible and NULL-hidden Bool children" do
    w98_writer_bool_with_parent do |parent|
      keys = [1_u64]
      bool_map = [{10_u64, false}] of Tuple(UInt64, Bool)
      bool_rows = [[bool_map]] of Array(Array(Tuple(UInt64, Bool)))
      bool_part = File.join(parent, "array-map-bool")
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
        bool_part, "pk", keys.to_unsafe.to_slice(1), "payload", bool_rows.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_map_bool_stage(
        bool_part, bool_rows.to_unsafe.to_slice(1), 1
      )

      bool_mutated = File.join(parent, "array-map-bool-mutated")
      FileUtils.cp_r(bool_part, bool_mutated)
      bool_stream = CrystalClick::WidePartWriter.w98_test_array_map_bool_stream_name
      w98_writer_bool_replace_stream_byte(bool_mutated, bool_stream, 0, 2_u8)
      CrystalClick::WidePart.open_typed(bool_mutated, "payload")
        .read_array_map_uint64_bool_mark_range("payload", 0, 1)
        .should eq([[[{10_u64, true}]]])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_array_map_bool_stage(
          bool_mutated, bool_rows.to_unsafe.to_slice(1), 1
        )
      end

      nullable_map = [{"k", nil.as(Bool?)}] of Tuple(String, Bool?)
      nullable_rows = [[nullable_map]] of Array(Array(Tuple(String, Bool?)))
      nullable_part = File.join(parent, "array-map-nullable")
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(1), "payload", nullable_rows.to_unsafe.to_slice(1), 1
      )
      CrystalClick::WidePartWriter.w98_test_validate_array_map_string_nullable_bool_stage(
        nullable_part, nullable_rows.to_unsafe.to_slice(1), 1
      )

      nullable_mutated = File.join(parent, "array-map-nullable-mutated")
      FileUtils.cp_r(nullable_part, nullable_mutated)
      w98_writer_bool_replace_stream_byte(nullable_mutated, bool_stream, 0, 2_u8)
      CrystalClick::WidePart.open_typed(nullable_mutated, "payload")
        .read_array_map_string_nullable_bool_mark_range("payload", 0, 1)
        .should eq([[[{"k", nil.as(Bool?)}]]])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w98_test_validate_array_map_string_nullable_bool_stage(
          nullable_mutated, nullable_rows.to_unsafe.to_slice(1), 1
        )
      end
    end
  end
end
