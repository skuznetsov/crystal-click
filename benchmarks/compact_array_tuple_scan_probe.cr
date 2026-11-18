require "../src/crystal_click"

private alias EventRows = Slice(Array(Tuple(UInt64, String)))

private def write_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

private def write_event(io : IO, number : UInt64, text : Bytes) : Nil
  io.write_bytes(number, IO::ByteFormat::LittleEndian)
  write_varuint(io, text.size.to_u64)
  io.write(text)
end

private def serialize(io : IO, marks : Array(EventRows)) : Nil
  marks.each do |rows|
    rows.each do |row|
      write_varuint(io, row.size.to_u64)
      row.each { |number, text| write_event(io, number, text.to_slice) }
    end
  end
end

private def serialize(io : IO, marks : Array(CrystalClick::CompactArrayTupleUInt64StringMark)) : Nil
  marks.each do |mark|
    rows = mark.row_offsets
    numbers = mark.uint64_values
    mark.row_count.times do |index|
      start = rows[index].to_i
      finish = rows[index + 1].to_i
      write_varuint(io, (finish - start).to_u64)
      (start...finish).each { |item| write_event(io, numbers[item], mark.string_bytes_at(item)) }
    end
  end
end

private def measure(label : String, round : Int32, oracle : Bytes, &)
  GC.collect
  before = GC.stats.total_bytes
  started = Time.instant
  result = yield
  read_ms = (Time.instant - started).total_milliseconds
  allocated = GC.stats.total_bytes - before

  output = IO::Memory.new(oracle.size)
  started = Time.instant
  serialize(output, result)
  serialize_ms = (Time.instant - started).total_milliseconds
  raise "#{label} output differs from ClickHouse RowBinary" unless output.to_slice == oracle
  puts "#{round},#{label},#{read_ms},#{serialize_ms},#{allocated}" if round >= 0
end

abort "usage: compact_array_tuple_scan_probe PART EVENTS_ROWBINARY" unless ARGV.size == 2
part_path, oracle_path = ARGV
declaration = CrystalClick::WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse(declaration).not_nil!
direct = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, "events", type)
legacy = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, "events", type)
oracle = File.read(oracle_path).to_slice
raise "fixture must contain 8192 rows in four positive marks" unless direct.row_count == 8192 && direct.mark_count == 4

direct_scan = -> {
  Array.new(direct.mark_count) { |mark| direct.read_array_tuple_uint64_string_mark(mark) }
}
legacy_scan = -> {
  Array(EventRows).new(legacy.mark_count) do |mark|
    values = legacy.read_marks(mark, 1).first
    batch = CrystalClick::WidePartTableBatch.new(
      0, File.basename(part_path), part_path, mark, 0_u64, 0_u64, 0_u64,
      ["events"], [type.name], [] of CrystalClick::WidePartNumericSlice,
      row_count: values.size.to_u64,
    )
    view = Slice.new(values.to_unsafe, values.size)
    CrystalClick::BinaryValueTypedBatchAdapter.install(batch, "events", type, view, values.size)
    batch.array_tuple_uint64_string_for("events")
  end
}

puts "round,route,read_ms,serialize_ms,read_allocated_bytes"
(-2...16).each do |round|
  if round.even?
    measure("legacy", round, oracle) { legacy_scan.call }
    measure("flat", round, oracle) { direct_scan.call }
  else
    measure("flat", round, oracle) { direct_scan.call }
    measure("legacy", round, oracle) { legacy_scan.call }
  end
end
