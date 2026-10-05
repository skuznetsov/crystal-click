require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w168_types"

# The public readers called by the W168 staged writer validator are overridden
# only while a test explicitly enables this inert probe. The returned value is
# changed after the real reader completes, so the writer must reject the
# staged mark before publishing its directory.
class CrystalClick::WidePart
  class_property w168_text_probe_enabled = false
  class_property w168_text_probe_kind = ""
  class_property w168_text_probe_mark = -1
  class_property w168_scalar_string_calls = [] of Tuple(String, Int32, Int32, Array(String))
  class_property w168_scalar_fixed_calls = [] of Tuple(String, Int32, Int32, Array(String))
  class_property w168_nullable_string_calls = [] of Tuple(String, Int32, Int32, Array(String?))
  class_property w168_nullable_fixed_calls = [] of Tuple(String, Int32, Int32, Array(String?))

  def self.w168_begin_text_probe(kind : String, mismatch_mark : Int32 = -1) : Nil
    self.w168_scalar_string_calls = [] of Tuple(String, Int32, Int32, Array(String))
    self.w168_scalar_fixed_calls = [] of Tuple(String, Int32, Int32, Array(String))
    self.w168_nullable_string_calls = [] of Tuple(String, Int32, Int32, Array(String?))
    self.w168_nullable_fixed_calls = [] of Tuple(String, Int32, Int32, Array(String?))
    self.w168_text_probe_kind = kind
    self.w168_text_probe_mark = mismatch_mark
    self.w168_text_probe_enabled = true
  end

  def self.w168_end_text_probe : Nil
    self.w168_text_probe_enabled = false
    self.w168_text_probe_kind = ""
    self.w168_text_probe_mark = -1
  end

  def read_simple_aggregate_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
    observed = previous_def
    if CrystalClick::WidePart.w168_text_probe_enabled
      if CrystalClick::WidePart.w168_text_probe_kind == "scalar_string" && first_mark == CrystalClick::WidePart.w168_text_probe_mark
        raise "W168 mismatch probe needs a nonempty String slot" if observed.empty? || observed[0].empty?
        observed[0] = observed[0] + "!"
      end
      CrystalClick::WidePart.w168_scalar_string_calls << {column, first_mark.to_i32, mark_count.to_i32, observed.dup}
    end
    observed
  end

  def read_simple_aggregate_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
    observed = previous_def
    if CrystalClick::WidePart.w168_text_probe_enabled
      if CrystalClick::WidePart.w168_text_probe_kind == "scalar_fixed" && first_mark == CrystalClick::WidePart.w168_text_probe_mark
        raise "W168 mismatch probe needs a nonempty FixedString slot" if observed.empty? || observed[0].empty?
        bytes = observed[0].to_slice.dup
        bytes[0] ^= 1_u8
        observed[0] = String.new(bytes)
      end
      CrystalClick::WidePart.w168_scalar_fixed_calls << {column, first_mark.to_i32, mark_count.to_i32, observed.dup}
    end
    observed
  end

  def read_nullable_simple_aggregate_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
    observed = previous_def
    if CrystalClick::WidePart.w168_text_probe_enabled
      if CrystalClick::WidePart.w168_text_probe_kind == "nullable_string" && first_mark == CrystalClick::WidePart.w168_text_probe_mark
        raise "W168 mismatch probe needs a nonempty Nullable(String) mark" if observed.empty? || observed[0].nil?
        observed[0] = observed[0].not_nil! + "!"
      end
      CrystalClick::WidePart.w168_nullable_string_calls << {column, first_mark.to_i32, mark_count.to_i32, observed.dup}
    end
    observed
  end

  def read_nullable_simple_aggregate_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
    observed = previous_def
    if CrystalClick::WidePart.w168_text_probe_enabled
      if CrystalClick::WidePart.w168_text_probe_kind == "nullable_fixed" && first_mark == CrystalClick::WidePart.w168_text_probe_mark
        raise "W168 mismatch probe needs a nonempty Nullable(FixedString) mark" if observed.empty? || observed[0].nil?
        observed[0] = nil
      end
      CrystalClick::WidePart.w168_nullable_fixed_calls << {column, first_mark.to_i32, mark_count.to_i32, observed.dup}
    end
    observed
  end

  def self.w168_read_u64(bytes : Bytes, offset : Int32) : UInt64
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  def self.w168_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
    8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
end

# These bridges are test-only: the production public writers remain the source
# of valid parts, and the helpers only exercise the same private exact-type and
# checksum boundaries already used by production staging.
module CrystalClick::WidePartWriter
  def self.w168_test_write_typed_pair_with_type(
    destination : String,
    keys : Slice(UInt64),
    values : Slice(T),
    type_name : String,
  ) : String forall T
    write_uint64_typed_pair_with_type(destination, "pk", keys, "v", values, type_name, 2)
  end

  def self.w168_test_rewrite_nullable_fixed_hidden_bytes(
    part : String,
    column : String,
    mark_index : Int32,
    row_in_mark : Int32,
    width : Int32,
  ) : Nil
    checksums = PartChecksums.open(part)
    base = StreamName.hash(column)
    data_path = File.join(part, "#{base}.bin")
    marks_path = File.join(part, "#{base}.mrk2")
    encoded = File.read(data_path).to_slice
    marks = File.read(marks_path).to_slice.dup
    start = WidePart.w168_read_u64(marks, mark_index * WidePart::MARK_SIZE).to_i64
    frame = CompressedBlock.decode_frame(
      encoded,
      start,
      PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
      PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES
    )
    raw = frame.output.dup
    raw[row_in_mark * width] = 0xa5_u8
    replacement = StreamEncoding.encode_lz4_frame(raw)
    old_end = frame.end_offset.to_i32
    delta = replacement.size - (old_end - start.to_i32)
    suffix = encoded[old_end, encoded.size - old_end]
    output = IO::Memory.new
    output.write(encoded[0, start.to_i32])
    output.write(replacement)
    output.write(suffix)
    File.write(data_path, output.to_slice)

    record_count = marks.size // WidePart::MARK_SIZE
    index = mark_index + 1
    while index < record_count
      offset = index * WidePart::MARK_SIZE
      prior = WidePart.w168_read_u64(marks, offset)
      shifted = delta >= 0 ? prior + delta.to_u64 : prior - (-delta).to_u64
      WidePart.w168_write_u64(marks, offset, shifted)
      index += 1
    end
    File.write(marks_path, marks)

    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      if entry.compressed
        decoded = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(
          bytes,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, CityHashV1.file_hash(bytes), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded)
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(part, records)
    nil
  end

  def self.w168_test_write_combined_checksums(
    part : String,
    source_a : String,
    source_b : String,
    b_streams : Array(String),
  ) : Nil
    entries_a = PartChecksums.open(source_a).entries
    entries_b = PartChecksums.open(source_b).entries
    selected_b = b_streams.flat_map do |stream|
      base = StreamName.hash(stream)
      ["#{base}.bin", "#{base}.mrk2"]
    end
    names = (entries_a.keys + selected_b).uniq
    records = names.map do |name|
      entry = entries_a[name]? || entries_b[name]? || raise("W168 combined checksum source is missing #{name}")
      bytes = File.read(File.join(part, name)).to_slice
      if entry.compressed
        decoded = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(
          bytes,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        ChecksumRecord.new(
          name, bytes.size.to_u64, CityHashV1.file_hash(bytes), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded)
        )
      else
        ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(part, records)
    nil
  end
end

private def w168_keys : Array(UInt64)
  [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
end

private def w168_pad_fixed(value : String, width : Int32) : String
  bytes = Bytes.new(width, 0_u8)
  value.to_slice.copy_to(bytes) unless value.empty?
  String.new(bytes)
end

private def w168_scalar_values(carrier : String) : Array(String)
  values = W168SimpleAggregateTestSupport.values(carrier, native: false)[0, 5]
  if width = W168SimpleAggregateTestSupport.width_for(carrier)
    values.map { |value| w168_pad_fixed(value, width) }
  else
    values
  end
end

private def w168_nullable_values(carrier : String) : Array(String?)
  values = W168SimpleAggregateTestSupport.nullable_values(W168SimpleAggregateTestSupport.values(carrier, native: false)[0, 5])
  if width = W168SimpleAggregateTestSupport.width_for(carrier)
    values.map { |value| value.try { |entry| w168_pad_fixed(entry, width) } }
  else
    values
  end
end

private def w168_type_name(function_name : String, carrier : String, nullable : Bool) : String
  scalar = "SimpleAggregateFunction(#{function_name}, #{carrier})"
  nullable ? "Nullable(#{scalar})" : scalar
end

private def w168_create_catalog(root : String, part : String, type_name : String) : Nil
  database_uuid = "16800000-0000-4000-8000-000000000011"
  table_uuid = "16800000-0000-4000-8000-000000000012"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  nil
end

private def w168_materialized_string_bytes(values : Array(String)) : UInt64
  values.reduce(0_u64) { |total, value| total + value.bytesize.to_u64 }
end

private def w168_materialized_string_bytes(values : Array(String?)) : UInt64
  total = 0_u64
  values.each { |value| total += value.bytesize.to_u64 if value }
  total
end

private def w168_write_scalar_part(part : String, carrier : String, function : CrystalClick::BinarySimpleAggregateType::Function, values : Array(String)) : Nil
  keys = w168_keys
  if width = W168SimpleAggregateTestSupport.width_for(carrier)
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v", values.to_unsafe.to_slice(values.size), width, function, 2
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v", values.to_unsafe.to_slice(values.size), function, 2
    )
  end
  nil
end

private def w168_write_nullable_part(part : String, carrier : String, function : CrystalClick::BinarySimpleAggregateType::Function, values : Array(String?)) : Nil
  keys = w168_keys
  if width = W168SimpleAggregateTestSupport.width_for(carrier)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v", values.to_unsafe.to_slice(values.size), width, function, 2
    )
  else
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_string_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v", values.to_unsafe.to_slice(values.size), function, 2
    )
  end
  nil
end

private def w168_build_two_text_column_part(parent : String, value : String) : String
  source_a = File.join(parent, "source-a", "all_1_1_0")
  source_b = File.join(parent, "source-b", "all_1_1_0")
  destination = File.join(parent, "combined", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(source_a))
  FileUtils.mkdir_p(File.dirname(source_b))
  FileUtils.mkdir_p(File.dirname(destination))
  Dir.mkdir(destination)
  keys = [1_u64]
  values = [value]
  value_slice = values.to_unsafe.to_slice(values.size)
  key_slice = keys.to_unsafe.to_slice(keys.size)
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
    source_a, "pk", key_slice, "left", value_slice, CrystalClick::BinarySimpleAggregateType::Function::Any, 1
  )
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
    source_b, "pk", key_slice, "right", value_slice, CrystalClick::BinarySimpleAggregateType::Function::Any, 1
  )

  Dir.each_child(source_a) do |name|
    FileUtils.cp(File.join(source_a, name), File.join(destination, name)) unless name == "checksums.txt"
  end
  b_streams = ["right.size", "right"]
  b_streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["bin", "mrk2"].each do |extension|
      name = "#{base}.#{extension}"
      FileUtils.cp(File.join(source_b, name), File.join(destination, name))
    end
  end

  type = "SimpleAggregateFunction(any, String)"
  File.write(File.join(destination, "columns.txt"), "columns format version: 1\n3 columns:\n`pk` UInt64\n`left` #{type}\n`right` #{type}\n")
  File.write(
    File.join(destination, "columns_substreams.txt"),
    "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n" +
    "2 substreams for column `left`:\n\tleft.size\n\tleft\n" +
    "2 substreams for column `right`:\n\tright.size\n\tright\n"
  )
  CrystalClick::WidePartWriter.w168_test_write_combined_checksums(destination, source_a, source_b, b_streams)
  destination
end

private def w168_exercise_scalar_profile(root : String, function_name : String, function : CrystalClick::BinarySimpleAggregateType::Function, carrier : String) : Nil
  values = w168_scalar_values(carrier)
  keys = w168_keys
  part_parent = File.join(root, "scalar_#{function_name}_#{carrier.gsub("(", "_").gsub(")", "")}")
  Dir.mkdir(part_parent)
  part = File.join(part_parent, "all_1_1_0")
  w168_write_scalar_part(part, carrier, function, values)

  type_name = w168_type_name(function_name, carrier, false)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(type_name)
  reader.row_count.should eq(5_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
  if W168SimpleAggregateTestSupport.width_for(carrier)
    reader.read_simple_aggregate_fixed_string_mark_range("v", 0, reader.mark_count).should eq(values)
    reader.read_simple_aggregate_fixed_string_mark_range("v", 2, 1).should eq(values[4, 1])
  else
    reader.read_simple_aggregate_string_mark_range("v", 0, reader.mark_count).should eq(values)
    reader.read_simple_aggregate_string_mark_range("v", 2, 1).should eq(values[4, 1])
  end
  expect_raises(CrystalClick::BoundsError) { reader.read_simple_aggregate_string_mark_range("v", reader.mark_count, 1) } if carrier == "String"

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", type_name}])
  observed = [] of String
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    actual = W168SimpleAggregateTestSupport.width_for(carrier) ? batch.simple_aggregate_fixed_strings_for("v").to_a : batch.simple_aggregate_strings_for("v").to_a
    actual.should eq(expected)
    observed.concat(actual)
  end
  observed.should eq(values)

  window_values = [] of String
  table.scan_typed_window(1_u64, 3) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    actual = W168SimpleAggregateTestSupport.width_for(carrier) ? batch.simple_aggregate_fixed_strings_for("v").to_a : batch.simple_aggregate_strings_for("v").to_a
    actual.should eq(expected)
    window_values.concat(actual)
  end
  window_values.should eq(values[1, 3])
  empty_callbacks = 0
  table.scan_typed_window(5_u64, 2) { |_batch| empty_callbacks += 1 }
  empty_callbacks.should eq(0)

  catalog_root = File.join(root, "catalog_scalar_#{function_name}_#{carrier.gsub("(", "_").gsub(")", "")}")
  w168_create_catalog(catalog_root, part, type_name)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(type_name)
  budget = w168_materialized_string_bytes(values)
  offline_values = offline["v"].values(max_rows: 5_u64, max_string_bytes: budget).map { |value| value.as(String) }
  offline_values.should eq(values)
  expect_raises(CrystalClick::BoundsError) { offline["v"].values(max_rows: 5_u64, max_string_bytes: budget - 1_u64) }
  expected_versions = "\"string\":1"
  File.read(File.join(part, "serialization.json")).should eq(
    "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{#{expected_versions}},\"version\":1}"
  )
  nil
end

private def w168_exercise_nullable_profile(root : String, function_name : String, function : CrystalClick::BinarySimpleAggregateType::Function, carrier : String) : Nil
  values = w168_nullable_values(carrier)
  keys = w168_keys
  part_parent = File.join(root, "nullable_#{function_name}_#{carrier.gsub("(", "_").gsub(")", "")}")
  Dir.mkdir(part_parent)
  part = File.join(part_parent, "all_1_1_0")
  w168_write_nullable_part(part, carrier, function, values)

  type_name = w168_type_name(function_name, carrier, true)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(type_name)
  reader.row_count.should eq(5_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
  if W168SimpleAggregateTestSupport.width_for(carrier)
    reader.read_nullable_simple_aggregate_fixed_string_mark_range("v", 0, reader.mark_count).should eq(values)
    reader.read_nullable_simple_aggregate_fixed_string_mark_range("v", 2, 1).should eq(values[4, 1])
  else
    reader.read_nullable_simple_aggregate_string_mark_range("v", 0, reader.mark_count).should eq(values)
    reader.read_nullable_simple_aggregate_string_mark_range("v", 2, 1).should eq(values[4, 1])
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", type_name}])
  observed = [] of String?
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    actual = W168SimpleAggregateTestSupport.width_for(carrier) ? batch.nullable_simple_aggregate_fixed_strings_for("v").to_a : batch.nullable_simple_aggregate_strings_for("v").to_a
    actual.should eq(expected)
    observed.concat(actual)
  end
  observed.should eq(values)

  window_values = [] of String?
  table.scan_typed_window(1_u64, 3) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    actual = W168SimpleAggregateTestSupport.width_for(carrier) ? batch.nullable_simple_aggregate_fixed_strings_for("v").to_a : batch.nullable_simple_aggregate_strings_for("v").to_a
    actual.should eq(expected)
    window_values.concat(actual)
  end
  window_values.should eq(values[1, 3])
  empty_callbacks = 0
  table.scan_typed_window(5_u64, 2) { |_batch| empty_callbacks += 1 }
  empty_callbacks.should eq(0)

  catalog_root = File.join(root, "catalog_nullable_#{function_name}_#{carrier.gsub("(", "_").gsub(")", "")}")
  w168_create_catalog(catalog_root, part, type_name)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(type_name)
  budget = w168_materialized_string_bytes(values)
  offline_values = offline["v"].values(max_rows: 5_u64, max_string_bytes: budget).map { |value| value.as(String?) }
  offline_values.should eq(values)
  expect_raises(CrystalClick::BoundsError) { offline["v"].values(max_rows: 5_u64, max_string_bytes: budget - 1_u64) }
  expected_versions = "\"nullable\":0,\"string\":1"
  File.read(File.join(part, "serialization.json")).should eq(
    "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{#{expected_versions}},\"version\":1}"
  )
  nil
end

describe "W168 paired SimpleAggregateFunction String and FixedString whole-part paths" do
  it "admits empty-payload EOF only for the variable SAF String data lane" do
    scalar_string = CrystalClick::SimpleAggregateTextStoragePlan.for_type_name("SimpleAggregateFunction(any, String)").not_nil!
    nullable_string = CrystalClick::SimpleAggregateTextStoragePlan.for_type_name("Nullable(SimpleAggregateFunction(max, String))").not_nil!
    scalar_fixed = CrystalClick::SimpleAggregateTextStoragePlan.for_type_name("SimpleAggregateFunction(min, FixedString(3))").not_nil!
    nullable_fixed = CrystalClick::SimpleAggregateTextStoragePlan.for_type_name("Nullable(SimpleAggregateFunction(anyLast, FixedString(3)))").not_nil!

    scalar_string.empty_payload_stream?("v", "v").should be_true
    scalar_string.empty_payload_stream?("v", "v.size").should be_false
    nullable_string.empty_payload_stream?("v", "v").should be_true
    nullable_string.empty_payload_stream?("v", "v.size").should be_false
    nullable_string.empty_payload_stream?("v", "v.null").should be_false
    scalar_fixed.empty_payload_stream?("v", "v").should be_false
    nullable_fixed.empty_payload_stream?("v", "v").should be_false
    nullable_fixed.empty_payload_stream?("v", "v.null").should be_false
    CrystalClick::SimpleAggregateTextStoragePlan.for_type_name("String").should be_nil
  end

  it "round-trips all 16 scalar function/carrier profiles through direct, batch, window, and OfflineCatalog readers" do
    root = File.tempname("crystal-click-w168-scalar-profiles-")
    Dir.mkdir(root)
    begin
      W168SimpleAggregateTestSupport.profiles.each do |function_name, _slug, function|
        W168_SIMPLE_AGGREGATE_CARRIERS.each do |carrier|
          w168_exercise_scalar_profile(root, function_name, function, carrier)
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "round-trips all 16 outer Nullable function/carrier profiles without conflating NULL and empty" do
    root = File.tempname("crystal-click-w168-nullable-profiles-")
    Dir.mkdir(root)
    begin
      W168SimpleAggregateTestSupport.profiles.each do |function_name, _slug, function|
        W168_SIMPLE_AGGREGATE_CARRIERS.each do |carrier|
          w168_exercise_nullable_profile(root, function_name, function, carrier)
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps ordinary inference and accessors exact while rejecting wrong text shapes before staging" do
    root = File.tempname("crystal-click-w168-shape-guards-")
    Dir.mkdir(root)
    keys = w168_keys
    strings = ["", "x", "é", "\0", "tail"]
    nullable_strings = ["x", "", "é", nil, "tail"] of String?
    begin
      ordinary = File.join(root, "ordinary-string")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        ordinary, "pk", keys.to_unsafe.to_slice(keys.size), "v", strings.to_unsafe.to_slice(strings.size), 2
      )
      CrystalClick::WidePart.open_typed(ordinary, "v").column_type.should eq("String")
      CrystalClick::WidePart.open_typed(ordinary, "v").read_string_mark_range("v", 0, 3).should eq(strings)

      scalar_string = File.join(root, "scalar-saf-string")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
        scalar_string, "pk", keys.to_unsafe.to_slice(keys.size), "v", strings.to_unsafe.to_slice(strings.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, 2
      )
      scalar_reader = CrystalClick::WidePart.open_typed(scalar_string, "v")
      expect_raises(CrystalClick::UnsupportedFormatError) { scalar_reader.read_nullable_simple_aggregate_string_mark_range("v", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { scalar_reader.read_string_mark_range("v", 0, 1) }

      nullable_string = File.join(root, "nullable-saf-string")
      CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_string_pair(
        nullable_string, "pk", keys.to_unsafe.to_slice(keys.size), "v", nullable_strings.to_unsafe.to_slice(nullable_strings.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, 2
      )
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_string, "v")
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable_reader.read_simple_aggregate_string_mark_range("v", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable_reader.read_nullable_string_mark_range("v", 0, 1) }

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w168_test_write_typed_pair_with_type(
          File.join(root, "wrong-scalar-shape"), keys.to_unsafe.to_slice(keys.size), strings.to_unsafe.to_slice(strings.size),
          "Nullable(SimpleAggregateFunction(any, String))"
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w168_test_write_typed_pair_with_type(
          File.join(root, "wrong-nullable-shape"), keys.to_unsafe.to_slice(keys.size), nullable_strings.to_unsafe.to_slice(nullable_strings.size),
          "SimpleAggregateFunction(any, String)"
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
          File.join(root, "numeric-api-must-stay-numeric"), "pk", keys.to_unsafe.to_slice(keys.size), "v",
          strings.to_unsafe.to_slice(strings.size), CrystalClick::BinarySimpleAggregateType::Function::Any, 2
        )
      end
      Dir.children(root).should contain("ordinary-string")
      Dir.children(root).should contain("scalar-saf-string")
      Dir.children(root).should contain("nullable-saf-string")
      Dir.children(root).size.should eq(3)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects scalar String and nullable FixedString mark-one readback mismatches before publish and removes staging" do
    root = File.tempname("crystal-click-w168-staged-readback-")
    Dir.mkdir(root)
    publish_root = File.join(root, "publish")
    Dir.mkdir(publish_root)
    keys = w168_keys
    string_values = w168_scalar_values("String")
    nullable_fixed_values = w168_nullable_values("FixedString(3)")
    begin
      scalar_destination = File.join(publish_root, "scalar")
      CrystalClick::WidePart.w168_begin_text_probe("scalar_string", 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
            scalar_destination, "pk", keys.to_unsafe.to_slice(keys.size), "v", string_values.to_unsafe.to_slice(string_values.size),
            CrystalClick::BinarySimpleAggregateType::Function::Any, 2
          )
        end
        error.message.should eq("staged SimpleAggregateFunction text stream readback differs from input")
        CrystalClick::WidePart.w168_scalar_string_calls.should eq([
          {"v", 0_i32, 1_i32, string_values[0, 2]},
          {"v", 1_i32, 1_i32, [string_values[2] + "!", string_values[3]]},
        ])
      ensure
        CrystalClick::WidePart.w168_end_text_probe
      end
      File.exists?(scalar_destination).should be_false
      Dir.children(publish_root).should be_empty

      nullable_destination = File.join(publish_root, "nullable-fixed")
      CrystalClick::WidePart.w168_begin_text_probe("nullable_fixed", 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
            nullable_destination, "pk", keys.to_unsafe.to_slice(keys.size), "v", nullable_fixed_values.to_unsafe.to_slice(nullable_fixed_values.size), 3,
            CrystalClick::BinarySimpleAggregateType::Function::Any, 2
          )
        end
        error.message.should eq("staged Nullable SimpleAggregateFunction text stream readback differs from input")
        altered = nullable_fixed_values[2, 2]
        altered[0] = nil
        CrystalClick::WidePart.w168_nullable_fixed_calls.should eq([
          {"v", 0_i32, 1_i32, nullable_fixed_values[0, 2]},
          {"v", 1_i32, 1_i32, altered},
        ])
      ensure
        CrystalClick::WidePart.w168_end_text_probe
      end
      File.exists?(nullable_destination).should be_false
      Dir.children(publish_root).should be_empty
    ensure
      CrystalClick::WidePart.w168_end_text_probe
      FileUtils.rm_rf(root)
    end
  end

  it "accepts FixedString widths one and 65536, pads short values, and rejects invalid widths before stage creation" do
    root = File.tempname("crystal-click-w168-width-guards-")
    Dir.mkdir(root)
    keys = [1_u64]
    function = CrystalClick::BinarySimpleAggregateType::Function::Any
    begin
      {1, 65_536}.each do |width|
        value = [""]
        scalar_part = File.join(root, "scalar-#{width}")
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
          scalar_part, "pk", keys.to_unsafe.to_slice(1), "v", value.to_unsafe.to_slice(1), width.to_i32, function, 1
        )
        scalar_reader = CrystalClick::WidePart.open_typed(scalar_part, "v")
        scalar_reader.column_type.should eq("SimpleAggregateFunction(any, FixedString(#{width}))")
        scalar_reader.read_simple_aggregate_fixed_string_mark_range("v", 0, 1).should eq([String.new(Bytes.new(width, 0_u8))])

        nullable_part = File.join(root, "nullable-#{width}")
        null_value = [nil] of String?
        CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
          nullable_part, "pk", keys.to_unsafe.to_slice(1), "v", null_value.to_unsafe.to_slice(1), width.to_i32, function, 1
        )
        nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "v")
        nullable_reader.column_type.should eq("Nullable(SimpleAggregateFunction(any, FixedString(#{width})))")
        nullable_reader.read_nullable_simple_aggregate_fixed_string_mark_range("v", 0, 1).should eq([nil])
      end

      {0, 65_537}.each do |width|
        scalar_destination = File.join(root, "invalid-scalar-#{width}")
        nullable_destination = File.join(root, "invalid-nullable-#{width}")
        null_value = [nil] of String?
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
            scalar_destination, "pk", keys.to_unsafe.to_slice(1), "v", [""].to_unsafe.to_slice(1), width.to_i32, function, 1
          )
        end
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_fixed_string_pair(
            nullable_destination, "pk", keys.to_unsafe.to_slice(1), "v", null_value.to_unsafe.to_slice(1), width.to_i32, function, 1
          )
        end
        File.exists?(scalar_destination).should be_false
        File.exists?(nullable_destination).should be_false
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_fixed_string_pair(
          File.join(root, "too-wide-payload"), "pk", keys.to_unsafe.to_slice(1), "v", ["xx"].to_unsafe.to_slice(1), 1, function, 1
        )
      end
      File.exists?(File.join(root, "too-wide-payload")).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "round-trips nonzero all-empty SAF(String) and all-NULL Nullable SAF(String) columns" do
    root = File.tempname("crystal-click-w168-empty-text-")
    Dir.mkdir(root)
    keys = [1_u64, 2_u64, 3_u64]
    scalar_values = ["", "", ""]
    nullable_values = [nil, nil, nil] of String?
    function = CrystalClick::BinarySimpleAggregateType::Function::Any
    begin
      scalar_parent = File.join(root, "scalar-empty")
      Dir.mkdir(scalar_parent)
      scalar_part = File.join(scalar_parent, "all_1_1_0")
      scalar_error_message : String? = nil
      begin
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
          scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", scalar_values.to_unsafe.to_slice(scalar_values.size), function, 2
        )
      rescue ex
        scalar_error_message = ex.message || ex.to_s
      end

      nullable_parent = File.join(root, "nullable-all-null")
      Dir.mkdir(nullable_parent)
      nullable_part = File.join(nullable_parent, "all_1_1_0")
      nullable_error_message : String? = nil
      begin
        CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_string_pair(
          nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", nullable_values.to_unsafe.to_slice(nullable_values.size), function, 2
        )
      rescue ex
        nullable_error_message = ex.message || ex.to_s
      end

      [scalar_error_message, nullable_error_message].should eq([nil, nil] of String?)

      scalar_reader = CrystalClick::WidePart.open_typed(scalar_part, "v")
      scalar_reader.row_count.should eq(3_u64)
      scalar_reader.mark_row_counts.should eq([2_u64, 1_u64])
      scalar_reader.read_simple_aggregate_string_mark_range("v", 0, 2).should eq(scalar_values)
      scalar_table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
      scalar_observed = [] of String
      scalar_table.scan_typed(batch_rows: 2) do |batch|
        scalar_observed.concat(batch.simple_aggregate_strings_for("v").to_a)
      end
      scalar_observed.should eq(scalar_values)
      scalar_catalog_root = File.join(root, "catalog-scalar-empty")
      w168_create_catalog(scalar_catalog_root, scalar_part, "SimpleAggregateFunction(any, String)")
      scalar_offline = CrystalClick::OfflineCatalog.open(scalar_catalog_root).table("lab", "events")
      scalar_offline["v"].values(max_rows: 3_u64, max_string_bytes: 0_u64).map { |value| value.as(String) }.should eq(scalar_values)

      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "v")
      nullable_reader.row_count.should eq(3_u64)
      nullable_reader.mark_row_counts.should eq([2_u64, 1_u64])
      nullable_reader.read_nullable_simple_aggregate_string_mark_range("v", 0, 2).should eq(nullable_values)
      nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
      nullable_observed = [] of String?
      nullable_table.scan_typed(batch_rows: 2) do |batch|
        nullable_observed.concat(batch.nullable_simple_aggregate_strings_for("v").to_a)
      end
      nullable_observed.should eq(nullable_values)
      nullable_catalog_root = File.join(root, "catalog-nullable-all-null")
      w168_create_catalog(nullable_catalog_root, nullable_part, "Nullable(SimpleAggregateFunction(any, String))")
      nullable_offline = CrystalClick::OfflineCatalog.open(nullable_catalog_root).table("lab", "events")
      nullable_offline["v"].values(max_rows: 3_u64, max_string_bytes: 0_u64).map { |value| value.as(String?) }.should eq(nullable_values)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads a positive-row empty terminal String mark after an earlier nonempty mark" do
    root = File.tempname("crystal-click-w168-empty-terminal-mark-")
    Dir.mkdir(root)
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    scalar_values = ["a", "b", "", ""]
    nullable_values = ["a", "b", nil, nil] of String?
    function = CrystalClick::BinarySimpleAggregateType::Function::Any
    begin
      scalar_parent = File.join(root, "scalar")
      Dir.mkdir(scalar_parent)
      scalar_part = File.join(scalar_parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_string_pair(
        scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", scalar_values.to_unsafe.to_slice(scalar_values.size), function, 2
      )
      scalar_payload_path = File.join(scalar_part, "#{CrystalClick::StreamName.hash("v")}.bin")
      File.size(scalar_payload_path).should be > 0
      scalar_reader = CrystalClick::WidePart.open_typed(scalar_part, "v")
      scalar_reader.mark_row_counts.should eq([2_u64, 2_u64])
      scalar_reader.simple_aggregate_string_mark_range_raw_bytes("v", 1, 1).should eq(0_u64)
      scalar_reader.read_simple_aggregate_string_mark_range("v", 0, 2).should eq(scalar_values)
      scalar_reader.read_simple_aggregate_string_mark_range("v", 1, 1).should eq(["", ""])
      scalar_table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
      scalar_observed = [] of String
      scalar_table.scan_typed(batch_rows: 2) do |batch|
        scalar_observed.concat(batch.simple_aggregate_strings_for("v").to_a)
      end
      scalar_observed.should eq(scalar_values)
      scalar_catalog = File.join(root, "catalog-scalar")
      w168_create_catalog(scalar_catalog, scalar_part, "SimpleAggregateFunction(any, String)")
      scalar_offline = CrystalClick::OfflineCatalog.open(scalar_catalog).table("lab", "events")
      scalar_offline["v"].values(max_rows: 4_u64, max_string_bytes: 2_u64).map { |value| value.as(String) }.should eq(scalar_values)

      nullable_parent = File.join(root, "nullable")
      Dir.mkdir(nullable_parent)
      nullable_part = File.join(nullable_parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_string_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", nullable_values.to_unsafe.to_slice(nullable_values.size), function, 2
      )
      nullable_payload_path = File.join(nullable_part, "#{CrystalClick::StreamName.hash("v")}.bin")
      File.size(nullable_payload_path).should be > 0
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "v")
      nullable_reader.mark_row_counts.should eq([2_u64, 2_u64])
      nullable_reader.nullable_simple_aggregate_string_mark_range_raw_bytes("v", 1, 1).should eq(0_u64)
      nullable_reader.read_nullable_simple_aggregate_string_mark_range("v", 0, 2).should eq(nullable_values)
      nullable_reader.read_nullable_simple_aggregate_string_mark_range("v", 1, 1).should eq([nil, nil] of String?)
      nullable_table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
      nullable_observed = [] of String?
      nullable_table.scan_typed(batch_rows: 2) do |batch|
        nullable_observed.concat(batch.nullable_simple_aggregate_strings_for("v").to_a)
      end
      nullable_observed.should eq(nullable_values)
      nullable_catalog = File.join(root, "catalog-nullable")
      w168_create_catalog(nullable_catalog, nullable_part, "Nullable(SimpleAggregateFunction(any, String))")
      nullable_offline = CrystalClick::OfflineCatalog.open(nullable_catalog).table("lab", "events")
      nullable_offline["v"].values(max_rows: 4_u64, max_string_bytes: 2_u64).map { |value| value.as(String?) }.should eq(nullable_values)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads and charges nonzero bytes beneath nullable FixedString NULL while OfflineCatalog exposes only visible values" do
    root = File.tempname("crystal-click-w168-hidden-null-fixed-")
    Dir.mkdir(root)
    part = File.join(root, "all_1_1_0")
    keys = w168_keys
    values = w168_nullable_values("FixedString(3)")
    begin
      w168_write_nullable_part(part, "FixedString(3)", CrystalClick::BinarySimpleAggregateType::Function::Any, values)
      stream = File.join(part, "#{CrystalClick::StreamName.hash("v")}.bin")
      raw_before = CrystalClick::CompressedBlock.decode_all(
        File.read(stream).to_slice,
        CrystalClick::PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
        CrystalClick::PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
        CrystalClick::PartChecksums::MAX_PAYLOAD_BYTES
      )
      raw_before[3 * 3, 3].should eq(Bytes.new(3, 0_u8))

      CrystalClick::WidePartWriter.w168_test_rewrite_nullable_fixed_hidden_bytes(part, "v", 1, 1, 3)
      reader = CrystalClick::WidePart.open_typed(part, "v")
      reader.read_nullable_simple_aggregate_fixed_string_mark_range("v", 0, 3).should eq(values)
      reader.nullable_simple_aggregate_fixed_string_mark_range_raw_bytes("v", 0, 3).should eq(15_u64)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      observed = [] of String?
      table.scan_typed(batch_rows: 2) do |batch|
        batch.nullable_simple_aggregate_fixed_strings_for("v").size.should eq(batch.values_for("pk", UInt64).size)
        observed.concat(batch.nullable_simple_aggregate_fixed_strings_for("v").to_a)
      end
      observed.should eq(values)

      type_name = "Nullable(SimpleAggregateFunction(any, FixedString(3)))"
      catalog_root = File.join(root, "catalog")
      w168_create_catalog(catalog_root, part, type_name)
      offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      visible_bytes = w168_materialized_string_bytes(values)
      offline["v"].values(max_rows: 5_u64, max_string_bytes: visible_bytes).map { |value| value.as(String?) }.should eq(values)
      expect_raises(CrystalClick::BoundsError) do
        offline["v"].values(max_rows: 5_u64, max_string_bytes: visible_bytes - 1_u64)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects combined over-budget String marks before the first typed table callback" do
    root = File.tempname("crystal-click-w168-combined-text-budget-")
    Dir.mkdir(root)
    begin
      large = String.new(Bytes.new(33 * 1024 * 1024, 0x41_u8))
      part = w168_build_two_text_column_part(root, large)
      left = CrystalClick::WidePart.open_typed(part, "left")
      right = CrystalClick::WidePart.open_typed(part, "right")
      left_bytes = left.simple_aggregate_string_mark_range_raw_bytes("left", 0, 1)
      right_bytes = right.simple_aggregate_string_mark_range_raw_bytes("right", 0, 1)
      limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      left_bytes.should be < limit
      right_bytes.should be < limit
      (left_bytes + right_bytes).should be > limit

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "left", "right"]).scan_typed do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
