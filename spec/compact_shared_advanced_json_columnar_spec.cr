require "./spec_helper"
require "file_utils"
require "digest/sha256"
require "../scripts/support/compact_physical_context_w259_fixture"

private module CompactJsonColumnarGuardFixture
  extend self

  COLUMN        = "root_json"
  KEY           = "pk"
  SITE          = "root"
  DYNAMIC_PATH  = "payload"
  ROW_COUNT     = 8
  ROWS_PER_MARK = 2
  SHARED_PATHS  = ["alpha", "aa", "beta"] +
                  (0...17).map { |index| "extra_#{index.to_s.rjust(2, '0')}" }.to_a

  def uint64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def nullable_uint64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(uint64)
  end

  def uint32 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt32")
  end

  def nullable_uint32 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(uint32)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 64,
      max_dynamic_types: 2,
      typed_paths: {
        "id"   => uint64,
        "rank" => nullable_uint64,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("columnar guard JSON schema was not admitted")
  end

  def context(shared_version : UInt64) : CrystalClick::CompactJsonWriteContext
    object = CrystalClick::ObjectStructure.new(
      [DYNAMIC_PATH] of String,
      version: 4_u64,
      shared_data_version: shared_version,
      bucket_count: 2_u64,
      statistics: CrystalClick::StructureStatistics.new([2_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    # Canonical Dynamic order is SharedVariant, String, UInt64. Both ordinary
    # arms occur in the first mark, so this is a real two-arm Dynamic witness.
    dynamic = CrystalClick::DynamicStructure.new(
      [string, uint64] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {DYNAMIC_PATH => dynamic} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.object_schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new({SITE => plan} of String => CrystalClick::ObjectDocumentPlan)
  end

  def document(row : Int32, base : UInt64 = 1_u64, replacement : Bool = false) : CrystalClick::ObjectDocument
    seed = replacement ? row + 23 : row
    fields = {
      "id"   => CrystalClick::BinaryValue.uint64(base + row.to_u64),
      "rank" => rank_value(row, replacement),
    } of String => CrystalClick::BinaryValue

    SHARED_PATHS.each_with_index do |path, path_index|
      fields[path] = CrystalClick::BinaryValue.string(shared_value(path, path_index, seed))
    end

    case row % 4
    when 0
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.string("text-#{seed.to_s.rjust(2, '0')}")
    when 1
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.uint64(70_000_u64 + seed.to_u64)
    when 2
      # The absent cell must remain distinct from the typed rank NULL.
    when 3
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.string("tail\0#{seed}")
    end
    CrystalClick::ObjectDocument.new(fields)
  end

  def documents(base : UInt64 = 1_u64, replacement : Bool = false) : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(ROW_COUNT) do |row|
      document(row.to_i32, base, replacement)
    end
  end

  def write_part(
    path : String,
    base : UInt64 = 1_u64,
    replacement : Bool = false,
    shared_version : UInt64 = 2_u64,
    frame_bytes : Int = 4096,
  ) : String
    rows = documents(base, replacement).map do |document|
      CrystalClick::StorageColumnValue.object_document(document)
    end.to_a
    granules = rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    json_column = CrystalClick::CompactPartColumn.json(COLUMN, schema, granules, context(shared_version))
    keys = Slice(UInt64).new(ROW_COUNT) { |index| base + index.to_u64 }
    CrystalClick::CompactPartWriter.write_uint64_columns(
      path,
      KEY,
      keys,
      [json_column] of CrystalClick::CompactPartColumn,
      rows_per_mark: ROWS_PER_MARK,
      frame_bytes: frame_bytes,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    )
  end

  def expected_rowbinary(
    document : CrystalClick::ObjectDocument,
  ) : Bytes
    entries = [] of Tuple(String, CrystalClick::BinaryValue)
    document.paths.each do |path|
      entries << {path, document.value_for(path)}
    end
    json_rowbinary(entries)
  end

  def rowbinary_from_batch(
    batch : CrystalClick::CompactJsonColumnarBatch,
    row : Int,
  ) : Bytes
    entries = [] of Tuple(String, CrystalClick::BinaryValue)
    batch.column_count.times do |index|
      column = batch.column_at(index)
      value = column.value_at(row)
      next unless value
      entries << {column.path, value}
    end
    json_rowbinary(entries)
  end

  def json_rowbinary(entries : Array(Tuple(String, CrystalClick::BinaryValue))) : Bytes
    output = IO::Memory.new
    json = IO::Memory.new
    json << '{'
    entries.each_with_index do |entry, index|
      json << ',' if index > 0
      JSON::Any.new(entry[0]).to_json(json)
      json << ':'
      write_json_value(json, entry[1])
    end
    json << '}'
    write_varuint(output, json.size.to_u64)
    output.write(json.to_slice)
    output.to_slice
  end

  def write_json_value(io : IO, value : CrystalClick::BinaryValue) : Nil
    return io << "null" if value.is_null?

    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_UINT32
      io << uint32_value(value)
    when CrystalClick::BinaryDataType::TAG_UINT64
      io << value.as_uint64
    when CrystalClick::BinaryDataType::TAG_INT64
      io << value.as_int64
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string).to_json(io)
    when CrystalClick::BinaryDataType::TAG_BOOL
      io << (value.as_bool ? "true" : "false")
    when CrystalClick::BinaryDataType::TAG_NULLABLE, CrystalClick::BinaryDataType::TAG_DYNAMIC
      write_json_value(io, value.child_at(0))
    else
      raise CrystalClick::UnsupportedFormatError.new("columnar guard cannot serialize JSON leaf #{value.type.name}")
    end
    nil
  end

  def uint32_value(value : CrystalClick::BinaryValue) : UInt32
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_UINT32 && value.byte_size == 4
      raise CrystalClick::UnsupportedFormatError.new("columnar guard expected UInt32 JSON leaf")
    end
    result = 0_u32
    4.times { |index| result |= value.byte_at(index).to_u32 << (index * 8) }
    result
  end

  def fixed_uint32(value : UInt32) : CrystalClick::BinaryValue
    bytes = Bytes.new(4) do |index|
      ((value >> (index * 8)) & 0xff_u32).to_u8
    end
    CrystalClick::BinaryValue.fixed(uint32, bytes)
  end

  def write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
    nil
  end

  def rank_value(row : Int32, replacement : Bool) : CrystalClick::BinaryValue
    type = nullable_uint64
    return CrystalClick::BinaryValue.nullable(type) if row == 1
    scalar = CrystalClick::BinaryValue.uint64((row + (replacement ? 100 : 10)).to_u64)
    CrystalClick::BinaryValue.nullable(type, scalar)
  end

  private def shared_value(path : String, path_index : Int32, seed : Int32) : String
    return "" if path == "alpha" && seed == 0
    return "long:" + ("x" * 256) if path == "alpha" && seed == 3
    return "bytes\0with\0nuls" if path == "aa" && seed == 1
    return "shared\0nul" if path == "beta" && seed == 5
    "#{path}:#{path_index}:#{seed}"
  end
end

private module CompactJsonOrdinaryStringBorrowFixture
  extend self

  COLUMN       = "root_json"
  KEY          = "pk"
  SITE         = "root"
  DYNAMIC_PATH = "payload"
  TITLE        = "title"
  ROW_COUNT    = 3

  def uint64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def int64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 4,
      max_dynamic_types: 2,
      typed_paths: {
        "id"  => uint64,
        TITLE => string,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("ordinary String borrow fixture JSON schema was not admitted")
  end

  def context(shared_version : UInt64) : CrystalClick::CompactJsonWriteContext
    object = CrystalClick::ObjectStructure.new(
      [DYNAMIC_PATH] of String,
      version: 4_u64,
      shared_data_version: shared_version,
      bucket_count: 2_u64,
      statistics: CrystalClick::StructureStatistics.new([2_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    dynamic = CrystalClick::DynamicStructure.new(
      [string, int64] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [1_u64, 0_u64, 1_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {DYNAMIC_PATH => dynamic} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.object_schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new({SITE => plan} of String => CrystalClick::ObjectDocumentPlan)
  end

  def title_bytes(row : Int32) : Bytes
    case row
    when 0
      Bytes[0x41_u8, 0x00_u8, 0xff_u8, 0x42_u8]
    when 1
      Bytes.empty
    else
      Bytes[0x44_u8, 0xff_u8, 0x00_u8]
    end
  end

  def payload_bytes : Bytes
    Bytes[0x50_u8, 0x00_u8, 0xfe_u8, 0x51_u8]
  end

  def documents : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(ROW_COUNT) do |row|
      fields = {
        "id"  => CrystalClick::BinaryValue.uint64((101 + row).to_u64),
        TITLE => CrystalClick::BinaryValue.string(String.new(title_bytes(row.to_i32))),
      } of String => CrystalClick::BinaryValue
      if row == 1
        fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.int64(-7_i64)
      elsif row == 0
        fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.string(String.new(payload_bytes))
      end
      CrystalClick::ObjectDocument.new(fields)
    end
  end

  def write_part(path : String, shared_version : UInt64) : String
    rows = documents.map { |document| CrystalClick::StorageColumnValue.object_document(document) }.to_a
    json_column = CrystalClick::CompactPartColumn.json(
      COLUMN,
      schema,
      [rows] of Array(CrystalClick::StorageColumnValue),
      context(shared_version),
    )
    keys = Slice(UInt64).new(ROW_COUNT) { |index| 101_u64 + index.to_u64 }
    CrystalClick::CompactPartWriter.write_uint64_columns(
      path,
      KEY,
      keys,
      [json_column] of CrystalClick::CompactPartColumn,
      rows_per_mark: ROW_COUNT,
      frame_bytes: 4096,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    )
  end
end

private def cjcv_assert_borrowed_string_cell!(
  column : CrystalClick::CompactJsonColumnarColumn,
  row : Int,
  expected : Bytes,
) : Nil
  observed = false
  column.with_cell_at(row) do |cell|
    bytes = cell.borrowed_string_bytes? || raise("expected a borrowed ordinary String cell")
    bytes.read_only?.should be_true
    bytes.to_a.should eq(expected.to_a)
    cell.owned_value?.should be_nil
    observed = true
  end.should be_true
  observed.should be_true
  nil
end

private def cjcv_assert_owned_string_snapshot!(
  batch : CrystalClick::CompactJsonColumnarBatch,
  path : String,
  row : Int,
  expected : Bytes,
) : Nil
  column = batch.column_for(path).not_nil!
  column.with_cell_at(row) do |cell|
    cell.borrowed_string_bytes?.should be_nil
    value = cell.owned_value?.not_nil!
    value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
    value.as_string.to_slice.to_a.should eq(expected.to_a)
  end.should be_true
  nil
end

private def cjcv_full_ordinary_string_snapshot(
  part : String,
) : CrystalClick::CompactJsonColumnarBatch
  table = CrystalClick::TypedPartTable.open_selected_typed(
    [part],
    [CompactJsonOrdinaryStringBorrowFixture::KEY, CompactJsonOrdinaryStringBorrowFixture::COLUMN],
  )
  callbacks = 0
  snapshot = nil.as(CrystalClick::CompactJsonColumnarBatch?)
  table.scan_compact_json_columnar(workers: 1, batch_rows: 2) do |batch|
    batch.row_count.should eq([2, 1][callbacks])
    title = batch.column_for(CompactJsonOrdinaryStringBorrowFixture::TITLE).not_nil!
    payload = batch.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!
    ids = batch.uint64_column(CompactJsonOrdinaryStringBorrowFixture::KEY)
    batch.row_count.times do |row|
      source_row = callbacks * 2 + row
      ids[row].should eq((101 + source_row).to_u64)
      cjcv_assert_borrowed_string_cell!(title, row, CompactJsonOrdinaryStringBorrowFixture.title_bytes(source_row.to_i32))
      if source_row == 1
        value = payload.value_at(row).not_nil!
        value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_INT64)
        value.as_int64.should eq(-7_i64)
      elsif source_row == 0
        value = payload.value_at(row).not_nil!
        value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
        value.as_string.to_slice.to_a.should eq(CompactJsonOrdinaryStringBorrowFixture.payload_bytes.to_a)
      else
        payload.present_at?(row).should be_false
        payload.value_at(row).should be_nil
      end
    end
    snapshot = batch.snapshot if callbacks == 0
    callbacks += 1
  end
  callbacks.should eq(2)
  snapshot.not_nil!
end

private def cjcv_filtered_ordinary_string_snapshot(
  part : String,
) : CrystalClick::CompactJsonColumnarBatch
  table = CrystalClick::TypedPartTable.open_selected_typed(
    [part],
    [CompactJsonOrdinaryStringBorrowFixture::KEY, CompactJsonOrdinaryStringBorrowFixture::COLUMN],
  )
  callbacks = 0
  snapshot = nil.as(CrystalClick::CompactJsonColumnarBatch?)
  predicate = ->(key : UInt64) { key != 102_u64 }
  table.scan_compact_json_filtered_rows(CompactJsonOrdinaryStringBorrowFixture::KEY, predicate, 1) do |batch, original_rows|
    callbacks += 1
    batch.row_count.should eq(2)
    batch.mark_row_offset.should eq(0_u64)
    batch.part_row_offset.should eq(0_u64)
    batch.source_row_offset.should eq(0_u64)
    original_rows.read_only?.should be_true
    original_rows.to_a.should eq([0_i32, 2_i32])
    batch.uint64_column(CompactJsonOrdinaryStringBorrowFixture::KEY).to_a.should eq([101_u64, 103_u64])

    title = batch.column_for(CompactJsonOrdinaryStringBorrowFixture::TITLE).not_nil!
    [0, 2].each_with_index do |source_row, packed_row|
      cjcv_assert_borrowed_string_cell!(title, packed_row, CompactJsonOrdinaryStringBorrowFixture.title_bytes(source_row.to_i32))
    end

    payload = batch.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!
    payload_value = payload.value_at(0).not_nil!
    payload_value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
    payload_value.as_string.to_slice.to_a.should eq(CompactJsonOrdinaryStringBorrowFixture.payload_bytes.to_a)
    payload.present_at?(1).should be_false
    payload.value_at(1).should be_nil
    snapshot = batch.snapshot
  end
  callbacks.should eq(1)
  snapshot.not_nil!
end

private def cjcv_copy_part_files(source : String, destination : String) : Nil
  Dir.children(source).reject { |name| name == "checksums.txt" }.sort.each do |name|
    target = File.join(destination, name)
    staged = "#{target}.replacement"
    FileUtils.cp(File.join(source, name), staged)
    File.rename(staged, target)
  end
  staged_checksums = File.join(destination, "checksums.txt.replacement")
  FileUtils.cp(File.join(source, "checksums.txt"), staged_checksums)
  File.rename(staged_checksums, File.join(destination, "checksums.txt"))
end

private def cjcv_bulk_stream_variant(
  source : CrystalClick::BinaryBulkStreams,
  overrides : Hash(String, Bytes) = Hash(String, Bytes).new,
  extra_roles : Hash(String, Bytes) = Hash(String, Bytes).new,
) : CrystalClick::BinaryBulkStreams
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  source.roles.each do |role|
    original = source.stream(role)
    bytes = overrides[role]? || original.bytes
    streams[role] = CrystalClick::BinaryBulkStream.new(bytes, [0_u64, bytes.size.to_u64])
  end
  extra_roles.each do |role, bytes|
    streams[role] = CrystalClick::BinaryBulkStream.new(bytes, [0_u64, bytes.size.to_u64])
  end
  CrystalClick::BinaryBulkStreams.new(source.mark_count, streams)
end

private def cjcv_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8
  end
  nil
end

private def cjcv_assert_nullable_uint32_decode_rejects(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::BinaryBulkStreams,
) : Nil
  expect_raises(CrystalClick::CorruptPartError) do
    CrystalClick::BinaryBulkCodec.decode_with_budget(
      type,
      streams,
      [3_u64],
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
    )
  end

  values = Slice(UInt32).new(3)
  nulls = Slice(UInt8).new(3)
  expect_raises(CrystalClick::CorruptPartError) do
    CrystalClick::BinaryBulkDecoder.decode_nullable_uint32_into(
      type,
      streams,
      [3_u64],
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      values,
      nulls,
    )
  end
end

private def cjcv_late_root_frame(part_path : String, mark_index : Int32) : Int32
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  window = physical.read_window(CompactJsonColumnarGuardFixture::COLUMN, mark_index, 1).granules.first
  window.shards.each do |shard|
    first, limit = physical.frame_index.touched_frame_bounds(shard.logical_start, shard.logical_end)
    return first if first < limit
  end
  raise "columnar fixture mark #{mark_index} has no root JSON frame"
end

private def cjcv_touched_frames(
  physical : CrystalClick::CompactPartPhysicalContext,
  column_name : String,
  mark_index : Int32,
) : Array(Int32)
  frames = [] of Int32
  window = physical.read_window(column_name, mark_index, 1).granules.first
  window.shards.each do |shard|
    first, limit = physical.frame_index.touched_frame_bounds(shard.logical_start, shard.logical_end)
    first.upto(limit - 1) { |frame| frames << frame }
  end
  frames.uniq
end

private def cjcv_find_subslice(haystack : Bytes, needle : Bytes) : Int32?
  return nil if needle.empty? || needle.size > haystack.size
  0.upto(haystack.size - needle.size) do |offset|
    matches = true
    needle.size.times do |index|
      unless haystack[offset + index] == needle[index]
        matches = false
        break
      end
    end
    return offset if matches
  end
  nil
end

# Change one byte in a Copy String while preserving its lane length, frame
# boundaries, compressed frame checksum, and outer part checksum manifest.
private def cjcv_rewrite_copy_string_byte(
  part_path : String,
  mark_index : Int32,
  text : String,
  replacement_byte : UInt8,
) : Nil
  copy_values_stream = "#{CompactJsonColumnarGuardFixture::COLUMN}.object_shared_data.copy.values"
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  root = physical.read_window(CompactJsonColumnarGuardFixture::COLUMN, mark_index, 1).granules.first
  copy = root.shards.find do |shard|
    shard.stream_name == copy_values_stream
  end || raise "columnar fixture mark #{mark_index} has no Copy values lane"
  local_offset = cjcv_find_subslice(copy.bytes, text.to_slice) ||
                 raise "columnar fixture Copy values lane does not contain #{text.inspect}"
  logical_offset = copy.logical_start + local_offset.to_i64

  data_path = File.join(part_path, "data.bin")
  data = File.read(data_path).to_slice.dup
  compressed_offset = 0_i64
  logical_base = 0_i64
  rewritten = false
  while compressed_offset < data.size
    frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset)
    logical_limit = logical_base + frame.output.size.to_i64
    if logical_offset >= logical_base && logical_offset < logical_limit
      output = frame.output.dup
      output[(logical_offset - logical_base).to_i] = replacement_byte
      encoded = CrystalClick::CompressedMarkWriter.encode_all(output, output.size)
      old_size = (frame.end_offset - compressed_offset).to_i
      encoded.size.should eq(old_size)
      encoded.copy_to(data.to_unsafe + compressed_offset.to_i, encoded.size)
      rewritten = true
      break
    end
    logical_base = logical_limit
    compressed_offset = frame.end_offset
  end
  rewritten.should be_true

  File.write(data_path, data)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

  # A physical read reopens both checksums and the newly written frame before
  # the filtered reader is asked to compare Copy with its per-path Data lane.
  reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
  reopened.mark_row_counts.should eq(Array(UInt64).new(4) { CompactJsonColumnarGuardFixture::ROWS_PER_MARK.to_u64 })
  verified = reopened.read_window(CompactJsonColumnarGuardFixture::COLUMN, mark_index, 1).granules.first
  verified_copy = verified.shards.find do |shard|
    shard.stream_name == copy_values_stream
  end || raise "columnar fixture Copy values lane disappeared after rewrite"
  verified_copy.logical_start.should eq(copy.logical_start)
  verified_copy.logical_end.should eq(copy.logical_end)
  verified_copy.bytes[local_offset].should eq(replacement_byte)
  nil
end

private def cjcv_scan_rows(
  table : CrystalClick::TypedPartTable,
  workers : Int,
  batch_rows : Int,
  expected_documents : Array(CrystalClick::ObjectDocument),
) : Tuple(Array(UInt64), Array(Bytes), Array(Tuple(Int32, UInt64, UInt64)))
  keys = [] of UInt64
  rowbinary = [] of Bytes
  locations = [] of Tuple(Int32, UInt64, UInt64)
  table.scan_compact_json_columnar(workers: workers, batch_rows: batch_rows) do |batch|
    key_slice = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
    key_slice.size.should eq(batch.row_count)
    expected_path_order = (CompactJsonColumnarGuardFixture::SHARED_PATHS + ["id", "payload", "rank"]).sort
    batch.columns.map(&.path).to_a.should eq(expected_path_order)
    batch.column_for("not-in-the-roster").should be_nil
    batch.part_index.should eq(0_i32)
    batch.part_path.empty?.should be_false
    File.basename(batch.part_path).should eq(batch.part_name)
    batch.column_for("id").not_nil!.fallback_type.should eq(CompactJsonColumnarGuardFixture.uint64)
    batch.column_for("rank").not_nil!.fallback_type.should eq(CompactJsonColumnarGuardFixture.nullable_uint64)
    batch.column_for("rank").not_nil!.has_nullable_uint32_lane?.should be_false
    batch.column_count.should be > CrystalClick::WidePartTable::MAX_COLUMNS

    batch.row_count.times do |row|
      key = key_slice[row]
      # The fixture uses one-based adjacent keys, and row order is global.
      first_document_key = expected_documents.first.value_for("id").not_nil!.as_uint64
      document_index = (key - first_document_key).to_i
      document = expected_documents[document_index]

      id_column = batch.column_for("id").not_nil!
      id_value = id_column.value_at(row).not_nil!
      id_column.row_count.should eq(batch.row_count)
      id_value.as_uint64.should eq(document.value_for("id").as_uint64)
      id_column.present_at?(row).should be_true

      rank_column = batch.column_for("rank").not_nil!
      rank_value = rank_column.value_at(row).not_nil!
      rank_column.present_at?(row).should be_true
      rank_column.type_at(row).should eq(CompactJsonColumnarGuardFixture.nullable_uint64)
      rank_column.nullable_at?(row).should be_true
      rank_value.is_null?.should eq(document.value_for("rank").is_null?)
      payload_column = batch.column_for("payload").not_nil!
      payload_column.fallback_type.should be_nil
      expected_payload = document.has_path?("payload") ? document.value_for("payload") : nil
      if expected_payload
        payload_column.present_at?(row).should be_true
        actual_payload = payload_column.value_at(row).not_nil!
        actual_payload.is_null?.should be_false
        payload_column.type_at(row).should eq(expected_payload.type)
        payload_column.nullable_at?(row).should be_false
        # The Dynamic arm is represented by its exact admitted actual value;
        # retaining a Dynamic wrapper here would change the root JSON type.
        actual_payload.type.name.should eq(expected_payload.type.name)
        case expected_payload.type.tag
        when CrystalClick::BinaryDataType::TAG_STRING
          actual_payload.as_string.should eq(expected_payload.as_string)
        when CrystalClick::BinaryDataType::TAG_UINT64
          actual_payload.as_uint64.should eq(expected_payload.as_uint64)
        else
          raise "unexpected Dynamic test value type: #{expected_payload.type.name}"
        end
      else
        payload_column.present_at?(row).should be_false
        payload_column.value_at(row).should be_nil
        payload_column.type_at(row).should be_nil
        payload_column.nullable_at?(row).should be_false
      end

      # The strongest sparse/null discriminator: row 1 has a present typed
      # Nullable NULL; row 2 has an absent Dynamic path.
      if document_index == 1
        rank_value.is_null?.should be_true
        payload_column.present_at?(row).should be_true
      elsif document_index == 2
        payload_column.present_at?(row).should be_false
      end

      rowbinary << CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row)
      keys << key
      locations << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset}
      expected_payload_for_row = CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      rowbinary.last.should eq(expected_payload_for_row)
      batch.mark_index.should eq((document_index // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32)
      (batch.mark_row_offset + row.to_u64).should eq((document_index % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64)
      (batch.part_row_offset + row.to_u64).should eq(document_index.to_u64)
      (batch.source_row_offset + row.to_u64).should eq(document_index.to_u64)
    end
    expect_raises(IndexError) { batch.column_for("id").not_nil!.value_at(batch.row_count) }
  end
  {keys, rowbinary, locations}
end

private def cjcv_scan_filtered(
  table : CrystalClick::TypedPartTable,
  packed_rows : Bool,
  filter_column : String,
  predicate : Proc(UInt64, Bool),
  workers : Int,
  & : CrystalClick::CompactJsonColumnarBatch, Slice(Int32) -> Nil
) : Nil
  if packed_rows
    table.scan_compact_json_filtered_rows(filter_column, predicate, workers) do |batch, original_mark_rows|
      yield batch, original_mark_rows
    end
  else
    table.scan_compact_json_filtered(filter_column, predicate, workers) do |batch, matching_rows|
      yield batch, matching_rows
    end
  end
  nil
end

describe "Compact shared Advanced root JSON columnar batches" do
  it "matches recursive Nullable(UInt32) decoding while retaining every nested payload byte" do
    type = CompactJsonColumnarGuardFixture.nullable_uint32
    input = [
      CrystalClick::BinaryValue.nullable(type, CompactJsonColumnarGuardFixture.fixed_uint32(0_u32)),
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, CompactJsonColumnarGuardFixture.fixed_uint32(UInt32::MAX)),
    ] of CrystalClick::BinaryValue
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [input] of Array(CrystalClick::BinaryValue))
    encoded.roles.should eq(["root.nested.data", "root.nulls"])
    encoded.stream("root.nulls").bytes.to_a.should eq([0_u8, 1_u8, 0_u8])

    nested = encoded.stream("root.nested.data").bytes
    nested.size.should eq(12)
    cjcv_write_u32(nested, 4, 0xdead_beef_u32)
    overrides = {"root.nested.data" => nested} of String => Bytes
    mutated = cjcv_bulk_stream_variant(encoded, overrides)

    recursive_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    recursive = CrystalClick::BinaryBulkCodec.decode_with_budget(type, mutated, [3_u64], recursive_budget)
    recursive.size.should eq(1)
    recursive.first.size.should eq(3)
    recursive.first[0].is_null?.should be_false
    CompactJsonColumnarGuardFixture.uint32_value(recursive.first[0].child_at(0)).should eq(0_u32)
    recursive.first[1].is_null?.should be_true
    recursive.first[2].is_null?.should be_false
    CompactJsonColumnarGuardFixture.uint32_value(recursive.first[2].child_at(0)).should eq(UInt32::MAX)

    direct_values = Slice(UInt32).new(3)
    direct_nulls = Slice(UInt8).new(3)
    direct_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    CrystalClick::BinaryBulkDecoder.decode_nullable_uint32_into(
      type,
      mutated,
      [3_u64],
      direct_budget,
      direct_values,
      direct_nulls,
    )
    direct_values.to_a.should eq([0_u32, 0xdead_beef_u32, UInt32::MAX])
    direct_nulls.to_a.should eq([0_u8, 1_u8, 0_u8])
    direct_budget.node_count.should eq(recursive_budget.node_count)
    direct_budget.element_count.should eq(recursive_budget.element_count)
    direct_budget.wire_byte_count.should eq(recursive_budget.wire_byte_count)
    direct_budget.wire_byte_count.should eq(15_i64)

    below_raw_lane_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_depth,
      max_nodes: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_nodes,
      max_elements: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_elements,
      max_bytes: 14,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode_with_budget(
        type,
        mutated,
        [3_u64],
        CrystalClick::BinaryCodecBudget.new(below_raw_lane_limits),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkDecoder.decode_nullable_uint32_into(
        type,
        mutated,
        [3_u64],
        CrystalClick::BinaryCodecBudget.new(below_raw_lane_limits),
        Slice(UInt32).new(3),
        Slice(UInt8).new(3),
      )
    end
  end

  it "rejects malformed direct Nullable(UInt32) lane grids like the recursive decoder" do
    type = CompactJsonColumnarGuardFixture.nullable_uint32
    input = [
      CrystalClick::BinaryValue.nullable(type, CompactJsonColumnarGuardFixture.fixed_uint32(0_u32)),
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, CompactJsonColumnarGuardFixture.fixed_uint32(UInt32::MAX)),
    ] of CrystalClick::BinaryValue
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [input] of Array(CrystalClick::BinaryValue))

    bad_flags = encoded.stream("root.nulls").bytes
    bad_flags[1] = 2_u8
    cjcv_assert_nullable_uint32_decode_rejects(
      type,
      cjcv_bulk_stream_variant(encoded, {"root.nulls" => bad_flags} of String => Bytes),
    )

    nested = encoded.stream("root.nested.data").bytes
    short_nested = Bytes.new(nested.size - 1) { |index| nested[index] }
    cjcv_assert_nullable_uint32_decode_rejects(
      type,
      cjcv_bulk_stream_variant(encoded, {"root.nested.data" => short_nested} of String => Bytes),
    )

    extended_nested = Bytes.new(nested.size + 1) do |index|
      index < nested.size ? nested[index] : 0xff_u8
    end
    cjcv_assert_nullable_uint32_decode_rejects(
      type,
      cjcv_bulk_stream_variant(encoded, {"root.nested.data" => extended_nested} of String => Bytes),
    )

    cjcv_assert_nullable_uint32_decode_rejects(
      type,
      cjcv_bulk_stream_variant(
        encoded,
        Hash(String, Bytes).new,
        {"root.unplanned" => Bytes[0_u8]} of String => Bytes,
      ),
    )

    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkDecoder.decode_nullable_uint32_into(
        type,
        encoded,
        [3_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        Slice(UInt32).new(2),
        Slice(UInt8).new(3),
      )
    end
  end

  it "borrows ordinary String lanes through full and masked scans and detaches snapshots" do
    parent = File.tempname("compact-json-ordinary-string-borrow-")
    begin
      Dir.mkdir(parent)
      [2_u64, 3_u64].each do |shared_version|
        version_parent = File.join(parent, "v#{shared_version}")
        Dir.mkdir(version_parent)
        part = File.join(version_parent, "all_1_1_0")
        CompactJsonOrdinaryStringBorrowFixture.write_part(part, shared_version)

        full_snapshot = cjcv_full_ordinary_string_snapshot(part)
        GC.collect
        full_snapshot.row_count.should eq(2)
        cjcv_assert_owned_string_snapshot!(
          full_snapshot,
          CompactJsonOrdinaryStringBorrowFixture::TITLE,
          0,
          CompactJsonOrdinaryStringBorrowFixture.title_bytes(0_i32),
        )
        cjcv_assert_owned_string_snapshot!(
          full_snapshot,
          CompactJsonOrdinaryStringBorrowFixture::TITLE,
          1,
          CompactJsonOrdinaryStringBorrowFixture.title_bytes(1_i32),
        )
        full_snapshot.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!.value_at(1).not_nil!.as_int64.should eq(-7_i64)
        full_payload = full_snapshot.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!.value_at(0).not_nil!
        full_payload.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
        full_payload.as_string.to_slice.to_a.should eq(CompactJsonOrdinaryStringBorrowFixture.payload_bytes.to_a)

        filtered_snapshot = cjcv_filtered_ordinary_string_snapshot(part)
        GC.collect
        filtered_snapshot.row_count.should eq(2)
        cjcv_assert_owned_string_snapshot!(
          filtered_snapshot,
          CompactJsonOrdinaryStringBorrowFixture::TITLE,
          0,
          CompactJsonOrdinaryStringBorrowFixture.title_bytes(0_i32),
        )
        cjcv_assert_owned_string_snapshot!(
          filtered_snapshot,
          CompactJsonOrdinaryStringBorrowFixture::TITLE,
          1,
          CompactJsonOrdinaryStringBorrowFixture.title_bytes(2_i32),
        )
        filtered_payload = filtered_snapshot.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!.value_at(0).not_nil!
        filtered_payload.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
        filtered_payload.as_string.to_slice.to_a.should eq(CompactJsonOrdinaryStringBorrowFixture.payload_bytes.to_a)
        filtered_snapshot.column_for(CompactJsonOrdinaryStringBorrowFixture::DYNAMIC_PATH).not_nil!.value_at(1).should be_nil
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  # The writer emits one chunk per row for SharedData v3; v2 uses one chunk per mark.
  [2_u64, 3_u64].each do |shared_version|
    it "emits exact RowBinary and split-relative locations with SharedData v#{shared_version}" do
      parent = File.tempname("compact-json-columnar-value-grid-")
      part = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactJsonColumnarGuardFixture.write_part(part, shared_version: shared_version)
        table = CrystalClick::TypedPartTable.open_selected_typed(
          [part],
          [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
        )
        expected_documents = CompactJsonColumnarGuardFixture.documents
        expected_keys = (1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a
        expected_locations = (0...CompactJsonColumnarGuardFixture::ROW_COUNT).map do |row|
          {(row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32,
           (row % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64,
           row.to_u64}
        end

        serial_keys, serial_json, serial_locations = cjcv_scan_rows(table, 1, 1, expected_documents)
        serial_keys.should eq(expected_keys)
        serial_json.should eq(expected_documents.map { |document| CompactJsonColumnarGuardFixture.expected_rowbinary(document) })
        serial_locations.should eq(expected_locations)

        parallel_keys, parallel_json, parallel_locations = cjcv_scan_rows(table, 4, 1, expected_documents)
        parallel_keys.should eq(serial_keys)
        parallel_json.should eq(serial_json)
        parallel_locations.should eq(serial_locations)

        # Two rows per mark, so batch_rows larger than one proves one callback
        # window can contain the complete mark and preserve its row order.
        whole_mark_keys, whole_mark_json, whole_mark_locations = cjcv_scan_rows(table, 4, 2, expected_documents)
        whole_mark_keys.should eq(serial_keys)
        whole_mark_json.should eq(serial_json)
        whole_mark_locations.should eq((0...CompactJsonColumnarGuardFixture::ROW_COUNT).map do |row|
          {(row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32,
           0_u64,
           (row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64 * CompactJsonColumnarGuardFixture::ROWS_PER_MARK.to_u64}
        end)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "retains exact Nullable(UInt32) lanes across windows and detached snapshots" do
    rank_type = CompactJsonColumnarGuardFixture.nullable_uint32
    empty_batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["rank"],
      [] of String,
      {} of String => CrystalClick::BinaryDataType,
      2,
      2_u64,
    )
    lane_batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["rank"],
      [] of String,
      {"rank" => rank_type} of String => CrystalClick::BinaryDataType,
      2,
      2_u64,
    )
    (lane_batch.retained_workspace_bytes - empty_batch.retained_workspace_bytes).should eq(10_u64)
    realistic_empty_batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["rank"],
      [] of String,
      {} of String => CrystalClick::BinaryDataType,
      CrystalClick::WidePartTable::MAX_MARK_ROWS.to_i,
      2_u64,
    )
    under_lane_budget = realistic_empty_batch.retained_workspace_bytes + 1_u64
    CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["rank"],
      [] of String,
      {} of String => CrystalClick::BinaryDataType,
      CrystalClick::WidePartTable::MAX_MARK_ROWS.to_i,
      2_u64,
      under_lane_budget,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactJsonColumnarBatch.from_layout(
        ["rank"],
        [] of String,
        {"rank" => rank_type} of String => CrystalClick::BinaryDataType,
        CrystalClick::WidePartTable::MAX_MARK_ROWS.to_i,
        2_u64,
        under_lane_budget,
      )
    end

    batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["rank", "payload"],
      [] of String,
      {"rank" => rank_type} of String => CrystalClick::BinaryDataType,
      2,
      16_u64,
    )
    batch.begin_mark!(0, "native-rank", "/native-rank", 0, 0_u64, 10_u64, 40_u64, 2_u64)
    lane = batch.begin_nullable_uint32_fill!("rank", rank_type).not_nil!
    lane[0][0] = 0xdead_beef_u32
    lane[0][1] = UInt32::MAX
    lane[1][0] = 1_u8
    lane[1][1] = 0_u8
    batch.complete_nullable_uint32_fill!("rank", 2)

    rank_column = batch.column_for("rank").not_nil!
    prior_rank_column = rank_column
    rank_column.has_nullable_uint32_lane?.should be_true
    rank_column.nullable_uint32_lane_active?.should be_true

    batch.set_window!(0, 2, 0_u64, 10_u64, 40_u64)
    values = rank_column.nullable_uint32_values
    nulls = rank_column.nullable_uint32_nulls
    values.size.should eq(2)
    nulls.size.should eq(2)
    values.read_only?.should be_true
    nulls.read_only?.should be_true
    value_address = values.to_unsafe.address
    null_address = nulls.to_unsafe.address
    values.to_a.should eq([0xdead_beef_u32, UInt32::MAX])
    nulls.to_a.should eq([1_u8, 0_u8])
    rank_column.present_at?(0).should be_true
    rank_column.type_at(0).should eq(rank_type)
    rank_column.nullable_at?(0).should be_true
    rank_column.value_at(0).not_nil!.is_null?.should be_true
    CompactJsonColumnarGuardFixture.uint32_value(rank_column.value_at(1).not_nil!.child_at(0)).should eq(UInt32::MAX)
    payload = batch.column_for("payload").not_nil!
    payload.present_at?(0).should be_false
    payload.value_at(0).should be_nil
    expect_raises(Exception) { values[0] = 1_u32 }
    expect_raises(Exception) { nulls[0] = 0_u8 }
    snapshot = batch.snapshot
    batch.mark_row_offset.should eq(0_u64)
    batch.part_row_offset.should eq(10_u64)

    batch.begin_mark!(0, "native-rank", "/native-rank", 1, 0_u64, 12_u64, 42_u64, 1_u64)
    rank_column.same?(prior_rank_column).should be_true
    rank_column.nullable_uint32_lane_active?.should be_false
    refill = batch.begin_nullable_uint32_fill!("rank", rank_type).not_nil!
    refill[0][0] = 0x1234_u32
    refill[1][0] = 0_u8
    batch.complete_nullable_uint32_fill!("rank", 1)
    batch.set_window!(0, 1, 0_u64, 12_u64, 42_u64)
    refill_values = rank_column.nullable_uint32_values
    refill_nulls = rank_column.nullable_uint32_nulls
    refill_values.to_unsafe.address.should eq(value_address)
    refill_nulls.to_unsafe.address.should eq(null_address)
    refill_values[0].should eq(0x1234_u32)
    refill_nulls[0].should eq(0_u8)
    value = rank_column.value_at(0).not_nil!
    CompactJsonColumnarGuardFixture.uint32_value(value.child_at(0)).should be > 0xff_u32
    batch.mark_index.should eq(1_i32)
    batch.part_row_offset.should eq(12_u64)
    batch.source_row_offset.should eq(42_u64)

    snapshot_rank = snapshot.column_for("rank").not_nil!
    snapshot_rank.nullable_uint32_values.to_a.should eq([0xdead_beef_u32, UInt32::MAX])
    snapshot_rank.nullable_uint32_nulls.to_a.should eq([1_u8, 0_u8])
    snapshot_rank.value_at(0).not_nil!.is_null?.should be_true
    CompactJsonColumnarGuardFixture.uint32_value(snapshot_rank.value_at(1).not_nil!.child_at(0)).should eq(UInt32::MAX)
    snapshot.mark_row_offset.should eq(0_u64)
    snapshot.part_row_offset.should eq(10_u64)
  end

  it "reuses one borrowed batch and column wrapper while a snapshot survives later windows" do
    parent = File.tempname("compact-json-columnar-snapshot-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      borrowed = nil.as(CrystalClick::CompactJsonColumnarBatch?)
      borrowed_id_column = nil.as(CrystalClick::CompactJsonColumnarColumn?)
      owned = nil.as(CrystalClick::CompactJsonColumnarBatch?)
      borrowed_snapshots = [] of Bytes
      callbacks = 0
      table.scan_compact_json_columnar(workers: 1, batch_rows: 1) do |batch|
        callbacks += 1
        if callbacks == 1
          borrowed = batch
          borrowed_id_column = batch.column_for("id")
          owned = batch.snapshot
          borrowed_snapshots << CompactJsonColumnarGuardFixture.rowbinary_from_batch(owned.not_nil!, 0)
        else
          batch.same?(borrowed.not_nil!).should be_true
          batch.column_for("id").not_nil!.same?(borrowed_id_column.not_nil!).should be_true
        end
        batch.row_count.should eq(1)
        batch.part_row_offset.should eq((callbacks - 1).to_u64)
        batch.mark_row_offset.should eq(((callbacks - 1) % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64)
        batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a.should eq([callbacks.to_u64])
      end
      callbacks.should eq(CompactJsonColumnarGuardFixture::ROW_COUNT)
      borrowed_snapshots.first.should eq(CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(0)))
      owned.not_nil!.part_row_offset.should eq(0_u64)
      owned.not_nil!.uint64_column(CompactJsonColumnarGuardFixture::KEY).should eq(Slice[1_u64])
      CompactJsonColumnarGuardFixture.rowbinary_from_batch(owned.not_nil!, 0).should eq(borrowed_snapshots.first)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "authenticates the whole selected grid before callbacks and retries cleanly" do
    parent = File.tempname("compact-json-columnar-grid-preflight-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      frame = cjcv_late_root_frame(part, 3_i32)
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, frame)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_columnar(workers: 4, batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      FileUtils.rm_rf(part)
      CompactJsonColumnarGuardFixture.write_part(part)
      reopened = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      keys, actual, _locations = cjcv_scan_rows(
        reopened,
        1,
        1,
        CompactJsonColumnarGuardFixture.documents,
      )
      keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)
      actual.should eq(CompactJsonColumnarGuardFixture.documents.map do |document|
        CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      end)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an output workspace budget before the first callback" do
    parent = File.tempname("compact-json-columnar-workspace-preflight-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_columnar(
          workers: 4,
          batch_rows: 1,
          workspace_limit: 1_u64,
        ) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps sparse column high-water slots charged across a disjoint reset" do
    batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["path-a", "path-b"],
      ["pk"],
      {} of String => CrystalClick::BinaryDataType,
      4,
      8_u64,
    )
    empty_workspace = batch.retained_workspace_bytes

    batch.begin_mark!(0, "part", "/part", 0, 0_u64, 0_u64, 0_u64, 4_u64)
    4.times do |row|
      batch.append_value!("path-a", row, CrystalClick::BinaryValue.string("a#{row}"))
    end
    first_companion = Bytes.new(32) do |index|
      value = (index // 8 + 1).to_u64
      ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
    end
    batch.fill_uint64_column!("pk", first_companion, 4_u64)
    batch.uint64_column("pk").to_a.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    batch.reset!
    after_reset = batch.retained_workspace_bytes
    slot_bytes = sizeof(Int32).to_u64 + sizeof(CrystalClick::CompactJsonColumnarCell).to_u64
    companion_slot_bytes = 4_u64 * sizeof(UInt64).to_u64
    (after_reset - empty_workspace).should eq(4_u64 * slot_bytes + companion_slot_bytes)

    batch.begin_mark!(0, "part", "/part", 1, 0_u64, 4_u64, 4_u64, 2_u64)
    2.times do |row|
      batch.append_value!("path-b", row, CrystalClick::BinaryValue.string("b#{row}"))
    end
    second_companion = Bytes.new(16) do |index|
      value = (index // 8 + 5).to_u64
      ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
    end
    batch.fill_uint64_column!("pk", second_companion, 2_u64)
    batch.uint64_column("pk").to_a.should eq([5_u64, 6_u64])
    batch.column_for("path-a").not_nil!.present_at?(0).should be_false
    batch.column_for("path-a").not_nil!.present_at?(1).should be_false
    batch.column_for("path-b").not_nil!.present_at?(0).should be_true
    batch.column_for("path-b").not_nil!.present_at?(1).should be_true
    batch.retained_workspace_bytes.should be > after_reset
  end

  it "rejects a valid same-path replacement between split callbacks and reopens its values" do
    parent = File.tempname("compact-json-columnar-replacement-")
    part = File.join(parent, "all_1_1_0")
    replacement = File.join(parent, "replacement_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      CompactJsonColumnarGuardFixture.write_part(replacement, 10_001_u64, true)
      [1, 2].each do |batch_rows|
        FileUtils.rm_rf(part)
        CompactJsonColumnarGuardFixture.write_part(part)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::TypedPartTable.open_selected_typed(
            [part],
            [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
          )
          table.scan_compact_json_columnar(workers: 4, batch_rows: batch_rows) do |_batch|
            callbacks += 1
            cjcv_copy_part_files(replacement, part) if callbacks == 1
          end
        end
        callbacks.should eq(1)
      end

      reopened = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      keys, actual, _locations = cjcv_scan_rows(
        reopened,
        4,
        1,
        CompactJsonColumnarGuardFixture.documents(10_001_u64, true),
      )
      keys.should eq((10_001_u64..(10_001_u64 + CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64 - 1_u64)).to_a)
      actual.should eq(CompactJsonColumnarGuardFixture.documents(10_001_u64, true).map do |document|
        CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      end)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows a nested scan and a later clean retry" do
    parent = File.tempname("compact-json-columnar-nested-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      outer_keys = [] of UInt64
      nested_keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 1, batch_rows: 1) do |batch|
        batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).each do |key|
          outer_keys << key
        end
        if outer_keys.size == 1
          table.scan_compact_json_columnar(workers: 1, batch_rows: 2) do |nested|
            nested_keys.concat(nested.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
          end
        end
      end
      expected = (1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a
      outer_keys.should eq(expected)
      nested_keys.should eq(expected)

      retry_keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |batch|
        retry_keys.concat(batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
      end
      retry_keys.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "emits mark-local survivor indexes in physical order and matches eager JSON rows" do
    parent = File.tempname("compact-json-filtered-order-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      documents = CompactJsonColumnarGuardFixture.documents
      eager_keys, eager_json, _eager_locations = cjcv_scan_rows(table, 1, 2, documents)
      eager_keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)

      predicate_keys = [] of UInt64
      callback_marks = [] of Int32
      callback_indices = [] of Array(Int32)
      callback_offsets = [] of Tuple(UInt64, UInt64)
      filtered_rows = [] of Tuple(UInt64, Bytes)
      table.scan_compact_json_filtered(
        CompactJsonColumnarGuardFixture::KEY,
        ->(key : UInt64) do
          predicate_keys << key
          key == 3_u64 || key == 8_u64
        end,
        workers: 4,
      ) do |batch, indices|
        batch.row_count.should eq(CompactJsonColumnarGuardFixture::ROWS_PER_MARK)
        indices.read_only?.should be_true
        callback_marks << batch.mark_index
        callback_indices << indices.to_a
        callback_offsets << {batch.part_row_offset, batch.source_row_offset}
        keys = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
        indices.each do |row|
          filtered_rows << {
            keys[row],
            CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row),
          }
        end
      end

      predicate_keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)
      callback_marks.should eq([1_i32, 3_i32])
      callback_indices.should eq([[0_i32], [1_i32]])
      callback_offsets.should eq([{2_u64, 2_u64}, {6_u64, 6_u64}])
      filtered_rows.should eq([
        {3_u64, eager_json[2]},
        {8_u64, eager_json[7]},
      ] of Tuple(UInt64, Bytes))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  [2_u64, 3_u64].each do |shared_version|
    it "packs only matching rows with physical offsets under SharedData v#{shared_version}" do
      parent = File.tempname("compact-json-filtered-packed-rows-")
      part = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactJsonColumnarGuardFixture.write_part(part, shared_version: shared_version)
        table = CrystalClick::TypedPartTable.open_selected_typed(
          [part],
          [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
        )
        documents = CompactJsonColumnarGuardFixture.documents
        expected_json = documents.map { |document| CompactJsonColumnarGuardFixture.expected_rowbinary(document) }
        expected_offsets = [
          [0_i32, 1_i32],
          [1_i32],
          [0_i32],
          [0_i32, 1_i32],
        ]
        expected_keys = [1_u64, 2_u64, 4_u64, 5_u64, 7_u64, 8_u64]
        predicate = ->(key : UInt64) { expected_keys.includes?(key) }

        [1, 4].each do |workers|
          callback_marks = [] of Int32
          packed_keys = [] of UInt64
          packed_json = [] of Bytes
          borrowed_batch = nil.as(CrystalClick::CompactJsonColumnarBatch?)
          borrowed_id_column = nil.as(CrystalClick::CompactJsonColumnarColumn?)
          owned_snapshot = nil.as(CrystalClick::CompactJsonColumnarBatch?)
          first_borrowed_offsets = nil.as(Array(Int32)?)
          table.scan_compact_json_filtered_rows(
            CompactJsonColumnarGuardFixture::KEY,
            predicate,
            workers: workers,
          ) do |batch, original_mark_rows|
            mark = batch.mark_index
            callback_marks << mark
            mark_start = (mark * CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64
            original_mark_rows.read_only?.should be_true
            original_mark_rows.to_a.should eq(expected_offsets[mark])
            batch.row_count.should eq(original_mark_rows.size)
            batch.mark_row_offset.should eq(0_u64)
            batch.part_row_offset.should eq(mark_start)
            batch.source_row_offset.should eq(mark_start)
            batch.part_index.should eq(0_i32)
            batch.columns.each { |column| column.row_count.should eq(batch.row_count) }

            if workers == 1
              if prior = borrowed_batch
                batch.same?(prior).should be_true
                batch.column_for("id").not_nil!.same?(borrowed_id_column.not_nil!).should be_true
              else
                borrowed_batch = batch
                borrowed_id_column = batch.column_for("id")
                owned_snapshot = batch.snapshot
                first_borrowed_offsets = original_mark_rows.to_a
              end
            end

            keys = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
            keys.size.should eq(batch.row_count)
            batch.row_count.times do |packed_row|
              source_row = mark_start.to_i + original_mark_rows[packed_row]
              key = keys[packed_row]
              key.should eq(source_row.to_u64 + 1_u64)
              predicate.call(key).should be_true
              packed_keys << key

              document = documents[source_row]
              rank = batch.column_for("rank").not_nil!
              rank.value_at(packed_row).not_nil!.is_null?.should eq(document.value_for("rank").is_null?)
              payload = batch.column_for("payload").not_nil!
              payload.present_at?(packed_row).should eq(document.has_path?(CompactJsonColumnarGuardFixture::DYNAMIC_PATH))

              rowbinary = CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, packed_row)
              rowbinary.should eq(expected_json[source_row])
              packed_json << rowbinary
            end
          end

          callback_marks.should eq([0_i32, 1_i32, 2_i32, 3_i32])
          packed_keys.should eq(expected_keys)
          packed_json.should eq(expected_keys.map { |key| expected_json[(key - 1_u64).to_i] })
          if workers == 1
            snapshot = owned_snapshot.not_nil!
            snapshot.row_count.should eq(2)
            CompactJsonColumnarGuardFixture.rowbinary_from_batch(snapshot, 0).should eq(expected_json[0])
            snapshot.uint64_column("pk").should eq(Slice[1_u64, 2_u64])
            first_borrowed_offsets.should eq([0_i32, 1_i32])
          end
        end
        predicate_calls = 0
        callbacks = 0
        table.scan_compact_json_filtered_rows(
          CompactJsonColumnarGuardFixture::KEY,
          ->(_key : UInt64) do
            predicate_calls += 1
            false
          end,
          workers: 4,
        ) { |_batch, _original_mark_rows| callbacks += 1 }
        predicate_calls.should eq(CompactJsonColumnarGuardFixture::ROW_COUNT)
        callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects malformed selected-row masks and accepts complete or nullable selections" do
    parent = File.tempname("compact-json-filtered-mask-shape-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      compact = CrystalClick::CompactPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      plan = compact.prepare_shared_advanced_json_scan.not_nil!
      plan.prepare_columnar_output!

      invalid_masks = [
        {Slice(Int32).new(0), "Compact JSON selected row mask is empty or exceeds its source mark"},
        {Slice[1_i32, 0_i32], "Compact JSON selected row mask is unordered, duplicated, or out of range"},
        {Slice[0_i32, 0_i32], "Compact JSON selected row mask is unordered, duplicated, or out of range"},
        {Slice[2_i32], "Compact JSON selected row mask is unordered, duplicated, or out of range"},
      ]
      invalid_masks.each do |mask, message|
        budget = plan.new_decode_budget
        plan.prepare_decode_budget!(budget)
        output = plan.new_columnar_output
        error = expect_raises(CrystalClick::CorruptPartError) do
          compact.scan_compact_json_columnar_mark_into(
            0,
            plan,
            budget,
            output,
            part_row_offset: 0_u64,
            matching_rows: mask,
          )
        end
        error.message.should eq(message)
      end

      full_budget = plan.new_decode_budget
      plan.prepare_decode_budget!(full_budget)
      full_output = plan.new_columnar_output
      compact.scan_compact_json_columnar_mark_into(
        0,
        plan,
        full_budget,
        full_output,
        part_row_offset: 0_u64,
        matching_rows: Slice[0_i32, 1_i32],
      )
      full_output.row_count.should eq(2)
      full_output.uint64_column(CompactJsonColumnarGuardFixture::KEY).should eq(Slice[1_u64, 2_u64])

      nullable_budget = plan.new_decode_budget
      plan.prepare_decode_budget!(nullable_budget)
      nullable_output = plan.new_columnar_output
      compact.scan_compact_json_columnar_mark_into(
        0,
        plan,
        nullable_budget,
        nullable_output,
        part_row_offset: 0_u64,
        matching_rows: Slice[1_i32],
      )
      nullable_output.row_count.should eq(1)
      nullable_output.uint64_column(CompactJsonColumnarGuardFixture::KEY).should eq(Slice[2_u64])
      nullable_output.mark_row_offset.should eq(0_u64)
      nullable_output.column_for("rank").not_nil!.value_at(0).not_nil!.is_null?.should be_true
      snapshot = nullable_output.snapshot
      snapshot.uint64_column(CompactJsonColumnarGuardFixture::KEY).should eq(Slice[2_u64])
      snapshot.column_for("rank").not_nil!.value_at(0).not_nil!.is_null?.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "skips zero-match and skipped-only JSON frames while strict scans still detect corruption" do
    parent = File.tempname("compact-json-filtered-skipped-frame-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part, frame_bytes: 512)
      physical = CrystalClick::CompactPartPhysicalContext.open(part)
      absent_json_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 0_i32)
      selected_json_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 1_i32) +
                             cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 3_i32)
      predicate_key_frames = (0_i32...4_i32).flat_map do |mark|
        cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, mark)
      end
      skipped_only_json_frames = absent_json_frames.reject do |frame|
        selected_json_frames.includes?(frame) || predicate_key_frames.includes?(frame)
      end
      skipped_only_json_frames.should_not be_empty
      skipped_frame = skipped_only_json_frames.first
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, skipped_frame)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )

      predicate_calls = 0
      zero_match_callbacks = 0
      table.scan_compact_json_filtered(
        CompactJsonColumnarGuardFixture::KEY,
        ->(_key : UInt64) do
          predicate_calls += 1
          false
        end,
        workers: 1,
      ) { |_batch, _indices| zero_match_callbacks += 1 }
      predicate_calls.should eq(CompactJsonColumnarGuardFixture::ROW_COUNT)
      zero_match_callbacks.should eq(0)

      callback_marks = [] of Int32
      callback_indices = [] of Array(Int32)
      filtered_rows = [] of Tuple(UInt64, Bytes)
      table.scan_compact_json_filtered(
        CompactJsonColumnarGuardFixture::KEY,
        ->(key : UInt64) { key == 3_u64 || key == 8_u64 },
        workers: 1,
      ) do |batch, indices|
        callback_marks << batch.mark_index
        callback_indices << indices.to_a
        keys = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
        indices.each do |row|
          filtered_rows << {
            keys[row],
            CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row),
          }
        end
      end
      callback_marks.should eq([1_i32, 3_i32])
      callback_indices.should eq([[0_i32], [1_i32]])
      filtered_rows.should eq([
        {3_u64, CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(2_i32))},
        {8_u64, CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(7_i32))},
      ] of Tuple(UInt64, Bytes))

      strict_callbacks = 0
      strict_error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_columnar(workers: 1, batch_rows: 1) do |_batch|
          strict_callbacks += 1
        end
      end
      strict_error.message.should eq("compressed frame checksum mismatch")
      strict_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-corrupt JSON frame in a selected mark before delivery" do
    parent = File.tempname("compact-json-filtered-selected-frame-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part, frame_bytes: 512)
      physical = CrystalClick::CompactPartPhysicalContext.open(part)
      selected_json_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 1_i32)
      predicate_key_frames = (0_i32...4_i32).flat_map do |mark|
        cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, mark)
      end
      selected_json_only_frames = selected_json_frames.reject do |frame|
        predicate_key_frames.includes?(frame)
      end
      selected_json_only_frames.should_not be_empty
      selected_frame = selected_json_only_frames.first
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, selected_frame)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_filtered(
          CompactJsonColumnarGuardFixture::KEY,
          ->(key : UInt64) { key == 3_u64 },
          workers: 1,
        ) do |_batch, _indices|
          callbacks += 1
        end
      end
      error.message.should eq("compressed frame checksum mismatch")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a valid-checksum Copy and Data disagreement in a selected mark" do
    parent = File.tempname("compact-json-filtered-copy-data-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      # beta is the third shared path, and row 2 supplies seed 2:
      # shared_value("beta", 2, 2) emits this exact Copy payload.
      cjcv_rewrite_copy_string_byte(part, 1_i32, "beta:2:2", 0x7a_u8)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_filtered(
          CompactJsonColumnarGuardFixture::KEY,
          ->(key : UInt64) { key == 3_u64 },
          workers: 1,
        ) do |_batch, _indices|
          callbacks += 1
        end
      end
      error.message.should eq("Object shared Copy value disagrees with its per-path Dynamic row")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "checks rejected sibling Copy rows before emitting packed survivors" do
    parent = File.tempname("compact-json-filtered-packed-rejected-copy-row-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      # This value belongs to key 4, which the predicate rejects. It shares
      # mark 1 with surviving key 3. The same-length rewrite refreshes both
      # the compressed-frame and outer part checksums, isolating Copy/Data
      # agreement in the rejected physical row.
      cjcv_rewrite_copy_string_byte(part, 1_i32, "beta:2:3", 0x7a_u8)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      predicate = ->(key : UInt64) { key == 3_u64 || key == 6_u64 || key == 8_u64 }

      [1, 4].each do |workers|
        callbacks = 0
        error = expect_raises(CrystalClick::CorruptPartError) do
          table.scan_compact_json_filtered_rows(
            CompactJsonColumnarGuardFixture::KEY,
            predicate,
            workers: workers,
          ) do |_batch, _original_mark_rows|
            callbacks += 1
          end
        end
        error.message.should eq("Object shared Copy value disagrees with its per-path Dynamic row")
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "revalidates selected JSON and predicate-key frames before later output and retry" do
    [:json, :key].each do |mutated_lane|
      parent = File.tempname("compact-json-filtered-between-callbacks-")
      part = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactJsonColumnarGuardFixture.write_part(part, frame_bytes: 512)
        physical = CrystalClick::CompactPartPhysicalContext.open(part)
        selected_json_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 1_i32) +
                               cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 3_i32)
        selected_key_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, 1_i32) +
                              cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, 3_i32)
        frame = if mutated_lane == :json
                  mark_three_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 3_i32)
                  mark_one_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::COLUMN, 1_i32)
                  all_key_frames = (0_i32...4_i32).flat_map do |mark|
                    cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, mark)
                  end
                  mark_three_frames.reject do |candidate|
                    mark_one_frames.includes?(candidate) || all_key_frames.includes?(candidate)
                  end.first || raise("columnar fixture has no selected-mark JSON-only frame after mark 1")
                else
                  skipped_mark_frames = cjcv_touched_frames(physical, CompactJsonColumnarGuardFixture::KEY, 2_i32)
                  skipped_mark_frames.reject do |candidate|
                    selected_key_frames.includes?(candidate) || selected_json_frames.includes?(candidate)
                  end.first || raise("columnar fixture has no skipped-mark key-only frame")
                end
        frame_mark = mutated_lane == :json ? 3_i32 : 2_i32
        frame_column = mutated_lane == :json ? CompactJsonColumnarGuardFixture::COLUMN : CompactJsonColumnarGuardFixture::KEY
        cjcv_touched_frames(physical, frame_column, frame_mark).includes?(frame).should be_true
        checksum_offset = physical.frame_index.frames[frame].compressed_offset
        original_frame_byte = File.open(File.join(part, "data.bin"), "r") do |data|
          data.seek(checksum_offset)
          data.read_byte.not_nil!
        end

        [false, true].each do |packed_rows|
          table = CrystalClick::TypedPartTable.open_selected_typed(
            [part],
            [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
          )
          predicate = ->(key : UInt64) { key == 3_u64 || key == 8_u64 }
          callbacks = 0
          error = expect_raises(CrystalClick::CorruptPartError) do
            cjcv_scan_filtered(
              table,
              packed_rows,
              CompactJsonColumnarGuardFixture::KEY,
              predicate,
              4,
            ) do |_batch, _indices|
              callbacks += 1
              if callbacks == 1
                File.open(File.join(part, "data.bin"), "r+") do |data|
                  data.seek(checksum_offset)
                  byte = data.read_byte.not_nil!
                  data.seek(checksum_offset)
                  data.write_byte(byte ^ 1_u8)
                end
              end
            end
          end
          error.message.should eq("Compact source frame checksum mismatch")
          callbacks.should eq(1)

          retry_callbacks = 0
          retry_error = expect_raises(CrystalClick::CorruptPartError) do
            cjcv_scan_filtered(
              table,
              packed_rows,
              CompactJsonColumnarGuardFixture::KEY,
              predicate,
              4,
            ) { |_batch, _indices| retry_callbacks += 1 }
          end
          # The original prepared scan detects a changed authenticated source
          # frame. On retry, preparing the affected predicate or JSON lane
          # decodes that now-corrupt compressed block and reports its frame
          # checksum directly, before any callback can run.
          retry_error.message.should eq("compressed frame checksum mismatch")
          retry_callbacks.should eq(0)

          File.open(File.join(part, "data.bin"), "r+") do |data|
            data.seek(checksum_offset)
            data.write_byte(original_frame_byte)
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "cleans up parallel callbacks after a callback error with multiple selected marks" do
    parent = File.tempname("compact-json-filtered-callback-error-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      expect_raises(ArgumentError) do
        table.scan_compact_json_filtered(
          CompactJsonColumnarGuardFixture::KEY,
          ->(key : UInt64) { key == 3_u64 || key == 8_u64 },
          workers: 4,
        ) do |_batch, _indices|
          callbacks += 1
          raise ArgumentError.new("intentional filtered callback failure")
        end
      end
      callbacks.should eq(1)

      retried_rows = [] of Tuple(UInt64, Bytes)
      table.scan_compact_json_filtered(
        CompactJsonColumnarGuardFixture::KEY,
        ->(key : UInt64) { key == 3_u64 || key == 8_u64 },
        workers: 4,
      ) do |batch, indices|
        keys = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
        indices.each do |row|
          retried_rows << {
            keys[row],
            CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row),
          }
        end
      end
      retried_rows.should eq([
        {3_u64, CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(2_i32))},
        {8_u64, CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(7_i32))},
      ] of Tuple(UInt64, Bytes))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans up parallel workers after a callback raises and allows the same table to rescan" do
    parent = File.tempname("compact-json-columnar-callback-error-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      expect_raises(ArgumentError) do
        table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |_batch|
          callbacks += 1
          raise ArgumentError.new("intentional callback failure")
        end
      end
      callbacks.should eq(1)

      keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |batch|
        keys.concat(batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
      end
      keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

private def cjcv_official_fixture_probe(part : String, oracle_path : String) : Nil
  table = CrystalClick::TypedPartTable.open_selected_typed([part], ["id", "doc"])
  table.column_types.any? { |name, type| name == "doc" && type.starts_with?("JSON(") }.should be_true
  expected_rowbinary = File.read(oracle_path)
  expected_bytes = expected_rowbinary.to_slice
  expected_rows = File.read(File.join(part, "count.txt")).strip.to_u64

  [1, 4].each do |workers|
    actual_bytes = IO::Memory.new
    observed_ids = [] of UInt64
    observed_documents = 0_u64
    table.scan_compact_json_columnar(workers: workers, batch_rows: 128) do |batch|
      ids = batch.uint64_column("id")
      ids.size.should eq(batch.row_count)
      rank = batch.column_for("rank").not_nil!
      rank.has_nullable_uint32_lane?.should be_true
      rank.nullable_uint32_lane_active?.should be_true
      rank_values = rank.nullable_uint32_values
      rank_nulls = rank.nullable_uint32_nulls
      rank_values.size.should eq(batch.row_count)
      rank_nulls.size.should eq(batch.row_count)
      batch.row_count.times do |row|
        id = ids[row]
        expected_null = id % 7_u64 == 0_u64
        rank_nulls[row].should eq(expected_null ? 1_u8 : 0_u8)
        unless expected_null
          rank_values[row].should eq((id % 32_768_u64).to_u32)
        end
        observed_ids << id
        observed_documents += 1_u64
        actual_bytes.write_bytes(id, IO::ByteFormat::LittleEndian)
        actual_bytes.write(CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row))
      end
    end
    observed_documents.should eq(expected_rows)
    observed_ids.size.to_u64.should eq(expected_rows)
    observed_ids.each_with_index do |id, index|
      id.should eq(index.to_u64)
    end
    actual = actual_bytes.to_slice
    unless actual == expected_bytes
      mismatch = 0
      limit = Math.min(actual.size, expected_bytes.size)
      while mismatch < limit && actual[mismatch] == expected_bytes[mismatch]
        mismatch += 1
      end
      actual_byte = mismatch < actual.size ? actual[mismatch] : nil
      expected_byte = mismatch < expected_bytes.size ? expected_bytes[mismatch] : nil
      raise "official RowBinary mismatch at byte #{mismatch}: actual=#{actual_byte.inspect} expected=#{expected_byte.inspect}; actual_size=#{actual.size} expected_size=#{expected_bytes.size}"
    end
  end
  nil
end

if fixture_root = ENV["CRYSTAL_CLICK_COLUMNAR_JSON_FIXTURE_ROOT"]?
  describe "official Compact JSON columnar fixture parity" do
    {"fixture", "overflow-fixture"}.each do |directory|
      it "matches the pinned RowBinary oracle and id/doc order for #{directory}" do
        part = File.join(fixture_root, directory, "0_1_1_0")
        oracle = File.join(fixture_root, directory, "0_1_1_0.rowbinary")
        cjcv_official_fixture_probe(part, oracle)
      end
    end

    it "matches the filtered ClickHouse RowBinary sequence on the overflow part" do
      part = File.join(fixture_root, "overflow-fixture", "0_1_1_0")
      oracle = File.read(File.join(fixture_root, "overflow-fixture", "0_1_1_0.rowbinary")).to_slice
      checksums_before = File.read(File.join(part, "checksums.txt"))
      data_path = File.join(part, "data.bin")
      data_hash_before = Digest::SHA256.hexdigest(File.read(data_path))
      predicate = ->(id : UInt64) { id // 2048_u64 % 2_u64 == 1_u64 && id % 4_u64 == 0_u64 }
      cursor = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, input: oracle)
      expected = IO::Memory.new
      until cursor.remaining_input_bytes == 0_u64
        start = cursor.input_offset
        id = IO::ByteFormat::LittleEndian.decode(UInt64, cursor.read_slice(8_u64))
        cursor.read_slice(cursor.read_var_uint)
        expected.write(oracle[start, cursor.input_offset - start]) if predicate.call(id)
      end

      mixed_predicate = ->(id : UInt64) do
        id // 2048_u64 % 2_u64 == 1_u64 && (id % 4_u64 == 0_u64 || id % 4_u64 == 3_u64)
      end
      mixed_cursor = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, input: oracle)
      expected_mixed = IO::Memory.new
      until mixed_cursor.remaining_input_bytes == 0_u64
        start = mixed_cursor.input_offset
        id = IO::ByteFormat::LittleEndian.decode(UInt64, mixed_cursor.read_slice(8_u64))
        mixed_cursor.read_slice(mixed_cursor.read_var_uint)
        expected_mixed.write(oracle[start, mixed_cursor.input_offset - start]) if mixed_predicate.call(id)
      end

      table = CrystalClick::TypedPartTable.open_selected_typed([part], ["id", "doc"])
      physical = CrystalClick::CompactPartPhysicalContext.open(part)
      mark_starts = [] of UInt64
      part_row_offset = 0_u64
      physical.mark_row_counts.each do |rows|
        mark_starts << part_row_offset
        part_row_offset += rows
      end
      [1, 4].each do |workers|
        output = IO::Memory.new
        marks = [] of Int32
        table.scan_compact_json_filtered("id", predicate, workers) do |batch, rows|
          marks << batch.mark_index
          ids = batch.uint64_column("id")
          rows.each do |row|
            output.write_bytes(ids[row], IO::ByteFormat::LittleEndian)
            output.write(CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row))
          end
        end
        marks.should eq([1_i32, 3_i32])
        output.to_slice.should eq(expected.to_slice)

        packed_output = IO::Memory.new
        packed_marks = [] of Int32
        observed_flags = [] of Bool
        table.scan_compact_json_filtered_rows("id", mixed_predicate, workers) do |batch, original_mark_rows|
          packed_marks << batch.mark_index
          original_mark_rows.read_only?.should be_true
          original_mark_rows.size.should eq(batch.row_count)
          batch.mark_row_offset.should eq(0_u64)
          batch.columns.each { |column| column.row_count.should eq(batch.row_count) }
          mark_start = mark_starts[batch.mark_index]
          batch.part_row_offset.should eq(mark_start)
          batch.source_row_offset.should eq(mark_start)
          original_mark_rows.size.should be < physical.mark_row_counts[batch.mark_index].to_i
          ids = batch.uint64_column("id")
          ids.size.should eq(batch.row_count)
          original_mark_rows.map { |row| mark_start + row.to_u64 }.to_a.should eq(ids.to_a)

          flags = batch.column_for("dynamic_flag").not_nil!
          ranks = batch.column_for("rank").not_nil!
          ranks.has_nullable_uint32_lane?.should be_true
          rank_values = ranks.nullable_uint32_values
          rank_nulls = ranks.nullable_uint32_nulls
          title = batch.column_for("title").not_nil!
          dynamic_value = batch.column_for("dynamic_value").not_nil!
          overflow_value = batch.column_for("overflow_0").not_nil!
          batch.row_count.times do |row|
            id = ids[row]
            mixed_predicate.call(id).should be_true
            flag = flags.value_at(row).not_nil!
            flag.as_bool.should eq(id.even?)
            observed_flags << flag.as_bool
            rank_nulls[row].should eq(id % 7_u64 == 0_u64 ? 1_u8 : 0_u8)
            unless id % 7_u64 == 0_u64
              rank_values[row].should eq((id % 32_768_u64).to_u32)
            end
            title.value_at(row).not_nil!.as_string.should eq("title-#{id.to_s.rjust(6, '0')}")
            spill = overflow_value.value_at(row).not_nil!.as_string
            spill.should eq("spill-0-#{(id % 43_u64).to_s.rjust(2, '0')}")
            dynamic = dynamic_value.value_at(row).not_nil!
            if id.even?
              dynamic.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
              dynamic.as_string.should eq("dv-#{(id % 19_u64).to_s.rjust(2, '0')}")
            else
              dynamic.type.tag.should eq(CrystalClick::BinaryDataType::TAG_INT64)
              dynamic.as_int64.should eq((id % 4_096_u64).to_i64)
            end
            packed_output.write_bytes(id, IO::ByteFormat::LittleEndian)
            packed_output.write(CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row))
          end
        end
        packed_marks.should eq([1_i32, 3_i32])
        observed_flags.includes?(false).should be_true
        observed_flags.includes?(true).should be_true
        packed_output.to_slice.should eq(expected_mixed.to_slice)
        packed_output.to_slice.should_not eq(output.to_slice)
      end
      File.read(File.join(part, "checksums.txt")).should eq(checksums_before)
      Digest::SHA256.hexdigest(File.read(data_path)).should eq(data_hash_before)
    end
  end
end
