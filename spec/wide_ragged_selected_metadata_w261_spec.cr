require "./spec_helper"
require "file_utils"
require "../scripts/support/wide_ragged_selected_metadata_w261_fixture"

module CrystalClick::WidePartWriter
  # Re-sign copied stock-part mutations so each adversary reaches its intended
  # metadata, roster, or mark-grid guard rather than the outer checksum gate.
  def self.w261_refresh_checksums(part : String, renames : Hash(String, String) = Hash(String, String).new) : Nil
    records = PartChecksums.open(part).entries.map do |name, entry|
      output_name = renames[name]? || name
      bytes = File.read(File.join(part, output_name)).to_slice
      if entry.compressed
        raw = bytes.empty? ? bytes : CompressedBlock.decode_all(bytes)
        ChecksumRecord.new(
          output_name,
          bytes.size.to_u64,
          CityHashV1.file_hash(bytes),
          true,
          raw.size.to_u64,
          CityHashV1.file_hash(raw),
        )
      else
        ChecksumRecord.new(output_name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(part, records)
  end
end

private def w261_with_stock_part(source : String, &block : String ->)
  parent = File.tempname("crystal-click-w261-stock-part-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    WideRaggedSelectedMetadataW261Fixture.copy_part_bytes(source, part)
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w261_info(name : String? = nil, children : Array(JSON::Any)? = nil) : JSON::Any
  fields = {
    "kind"         => JSON::Any.new("Default"),
    "num_defaults" => JSON::Any.new(0_i64),
    "num_rows"     => JSON::Any.new(8_i64),
  } of String => JSON::Any
  fields["name"] = JSON::Any.new(name.not_nil!) if name
  fields["subcolumns"] = JSON::Any.new(children.not_nil!) if children
  JSON::Any.new(fields)
end

private def w261_write_serialization(part : String, info : JSON::Any) : Nil
  File.write(File.join(part, "serialization.json"), info.to_json)
  CrystalClick::WidePartWriter.w261_refresh_checksums(part)
end

private def w261_write_records(part : String, records : Array(JSON::Any)) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  info.as_h["columns"] = JSON::Any.new(records)
  w261_write_serialization(part, info)
end

private def w261_rewrite_column_roster(part : String, column : String, mutation : Symbol = :reverse) : Nil
  path = File.join(part, "columns_substreams.txt")
  contents = File.read(path)
  lines = contents.split('\n')
  lines.pop if contents.ends_with?("\n") && lines.last? == ""
  header_index = lines.index { |line| line.ends_with?(" substreams for column `#{column}`:") } ||
                 raise "W261 selected physical roster is absent for #{column}"
  count = lines[header_index].split(' ', 2)[0].to_i
  original_names = lines[(header_index + 1), count].map do |line|
    raise "W261 physical roster line has no tab prefix" unless line.starts_with?("\t")
    String.new(line.to_slice[1, line.bytesize - 1])
  end
  names = case mutation
          when :reverse
            original_names.reverse
          when :missing
            original_names[0, original_names.size - 1]
          when :duplicate
            original_names + [original_names.last]
          when :extra
            original_names + ["#{column}.unexpected"]
          else
            raise "unknown W261 roster mutation: #{mutation}"
          end

  rewritten = [] of String
  index = 0
  while index < lines.size
    if index == header_index
      rewritten << "#{names.size} substreams for column `#{column}`:"
      names.each { |name| rewritten << "\t#{name}" }
      index += count + 1
    else
      rewritten << lines[index]
      index += 1
    end
  end
  result = rewritten.join("\n")
  result += "\n" if contents.ends_with?("\n")
  File.write(path, result)
  CrystalClick::WidePartWriter.w261_refresh_checksums(part)
end

private def w261_rename_uint64_sibling(part : String, old_name : String, new_name : String, wrong_stream : Bool = false) : Nil
  columns_path = File.join(part, "columns.txt")
  columns = File.read(columns_path)
  renamed_columns = columns.sub("`#{old_name}` UInt64", "`#{new_name}` UInt64")
  raise "W261 UInt64 sibling is absent from columns.txt" if renamed_columns == columns
  File.write(columns_path, renamed_columns)

  roster_path = File.join(part, "columns_substreams.txt")
  roster = File.read(roster_path)
  old_block = "1 substreams for column `#{old_name}`:\n\t#{old_name}\n"
  escaped_name = CrystalClick::PhysicalStreamName.escape(new_name)
  replacement_stream = wrong_stream ? "#{escaped_name}.wrong" : escaped_name
  renamed_roster = roster.sub(old_block, "1 substreams for column `#{new_name}`:\n\t#{replacement_stream}\n")
  raise "W261 UInt64 sibling is absent from columns_substreams.txt" if renamed_roster == roster
  File.write(roster_path, renamed_roster)

  # This is a byte-preserving physical rename, not just a logical roster
  # mutation: readers resolve the canonical escaped stream's hashed basename.
  old_stream = CrystalClick::PhysicalStreamName.escape(old_name)
  old_bases = [old_stream, CrystalClick::StreamName.hash(old_stream)].uniq.select do |base|
    File.file?(File.join(part, "#{base}.bin")) && File.file?(File.join(part, "#{base}.mrk2"))
  end
  raise "W261 UInt64 sibling does not have one plain .mrk2 stream pair" unless old_bases.size == 1
  old_base = old_bases.first
  new_base = CrystalClick::StreamName.hash(escaped_name)
  renames = Hash(String, String).new
  {".bin", ".mrk2"}.each do |extension|
    old_file = "#{old_base}#{extension}"
    new_file = "#{new_base}#{extension}"
    File.rename(File.join(part, old_file), File.join(part, new_file))
    renames[old_file] = new_file
  end

  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  if serializers = info["columns"]?.try(&.as_a)
    serializers.each do |serializer|
      entry = serializer.as_h
      entry["name"] = JSON::Any.new(new_name) if entry["name"]?.try(&.as_s) == old_name
    end
  end
  File.write(File.join(part, "serialization.json"), info.to_json)
  CrystalClick::WidePartWriter.w261_refresh_checksums(part, renames)
end

private def w261_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w261_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w261_corrupt_mark_rows(part : String, stream_name : String, mark_index : Int32) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
  w261_write_u64(marks, offset, w261_u64(marks, offset) + 1_u64)
  File.write(path, marks)
  CrystalClick::WidePartWriter.w261_refresh_checksums(part)
end

private def w261_corrupt_mark_decompressed_offset(
  part : String,
  stream_name : String,
  mark_index : Int32,
  delta : UInt64,
) : {UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  previous = w261_u64(marks, offset)
  raise "W261 mark-coordinate mutation overflows UInt64" if previous > UInt64::MAX - delta
  changed = previous + delta
  w261_write_u64(marks, offset, changed)
  File.write(path, marks)
  CrystalClick::WidePartWriter.w261_refresh_checksums(part)
  {previous, changed}
end

private def w261_offline_table(part : String) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 8_u64)
  columns = WideRaggedSelectedMetadataW261Fixture::SCHEMA.map do |name, type|
    CrystalClick::OfflineColumn.new(name, type)
  end
  CrystalClick::OfflineTable.new(
    "events",
    "w261-stock-ragged-selected-metadata",
    "MergeTree",
    columns,
    [candidate] of CrystalClick::OfflinePartCandidate,
    "pk",
  )
end

if stock_part = ENV["CRYSTAL_CLICK_W261_STOCK_PART"]?
  describe "W261 stock Wide ragged selected metadata admission" do
    it "reads Array(Tuple), Map(Tuple), and already-recognized Map families directly" do
      w261_with_stock_part(stock_part) do |part|
        seq_type = WideRaggedSelectedMetadataW261Fixture.schema_hash["seq"]
        seq_reader = CrystalClick::WidePart.open_typed(part, "seq")
        seq = seq_reader.read_array_tuple_mark_range("seq", 0, seq_reader.mark_count)
        seq.type_name.should eq(seq_type)
        seq.row_count.should eq(8)
        seq.element_count.should eq(5)
        seq.row_sizes.should eq([0_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64, 1_u64, 2_u64])
        seq.row(2)[0]["id"].should eq(1201_u64)
        seq.row(2)[0].tuple("details")["note"].should eq("a\0b")
        seq.row(2)[1].tuple("details")["note"].should be_nil
        seq.row(2)[1].tuple("details").value_as("score", UInt32).should eq(22_u32)
        seq.row(6)[0]["id"].should eq(1601_u64)
        seq.row(7)[1].tuple("details")["note"].should eq("last")
        seq.tuple_data["details.note"].null_map.not_nil!.bytes.should eq([0_u8, 1_u8, 0_u8, 0_u8, 0_u8])

        mapped_type = WideRaggedSelectedMetadataW261Fixture.schema_hash["mapped"]
        map_reader = CrystalClick::WidePart.open_typed(part, "mapped")
        mapped = map_reader.read_map_tuple_mark_range("mapped", 0, map_reader.mark_count)
        mapped.type_name.should eq(mapped_type)
        mapped.row_count.should eq(8)
        mapped.entry_count.should eq(6)
        mapped.row_sizes.should eq([0_u64, 0_u64, 3_u64, 0_u64, 0_u64, 0_u64, 1_u64, 2_u64])
        duplicate_row = mapped.row(2)
        duplicate_row.key_at(0).should eq("dup")
        duplicate_row.key_at(1).should eq("dup")
        duplicate_row.key_at(2).should eq("雪")
        duplicate_row.value_at(0).tuple("meta")["note"].should be_nil
        duplicate_row.value_at(0).tuple("meta").value_as("id", UInt64).should eq(2201_u64)
        duplicate_row.value_at(1).tuple("meta")["note"].should eq("m\0")
        duplicate_row.value_at(1)["score"].should be_nil
        mapped.row(6).value_at(0).tuple("meta").value_as("id", UInt64).should eq(2601_u64)
        mapped.row(7).key_at(0).should eq("end")
        mapped.row(7).key_at(1).should eq("end")
        mapped.row(7).value_at(1).tuple("meta")["note"].should be_nil

        simple_reader = CrystalClick::WidePart.open_typed(part, "simple")
        simple = simple_reader.read_map_uint64_nullable_uint64_mark_range("simple", 0, simple_reader.mark_count)
        simple.should eq([
          [{1_u64, nil}] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?),
          [{3_u64, 3003_u64}, {3_u64, 3004_u64}] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?),
          [{5_u64, 5005_u64}] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?),
          [{7_u64, nil}] of Tuple(UInt64, UInt64?),
        ])

        lookup_reader = CrystalClick::WidePart.open_typed(part, "lookup")
        lookup = lookup_reader.read_map_string_array_nullable_uint64_mark_range("lookup", 0, lookup_reader.mark_count)
        lookup.should eq([
          [] of Tuple(String, Array(UInt64?)),
          [{"one", [nil, 9202_u64]}] of Tuple(String, Array(UInt64?)),
          [] of Tuple(String, Array(UInt64?)),
          [{"empty", [] of UInt64?}, {"dup", [nil, 9401_u64]}] of Tuple(String, Array(UInt64?)),
          [] of Tuple(String, Array(UInt64?)),
          [] of Tuple(String, Array(UInt64?)),
          [{"π", [9606_u64, nil]}] of Tuple(String, Array(UInt64?)),
          [{"tail", [9707_u64] of UInt64?}] of Tuple(String, Array(UInt64?)),
        ])
      end
    end

    it "preserves arbitrary selected order, typed sibling contracts, full/window/EOF scans, and literal rows" do
      w261_with_stock_part(stock_part) do |part|
        selected = ["mapped", "tup", "u", "lookup", "seq", "side", "simple", "v", "lc"]
        table = CrystalClick::TypedPartTable.open_selected_typed([part], selected)
        schema = WideRaggedSelectedMetadataW261Fixture.schema_hash
        table.columns.should eq(selected)
        table.column_types.should eq(selected.map { |name| {name, schema[name]} })
        table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])
        table.total_row_count.should eq(8_u64)

        seq_rows = [] of CrystalClick::WideArrayTupleRow
        map_rows = [] of CrystalClick::WideMapTupleRow
        simple_rows = [] of Array(Tuple(UInt64, UInt64?))
        lookup_rows = [] of Array(Tuple(String, Array(UInt64?)))
        tuples = [] of CrystalClick::WideTupleRow
        u_values = [] of UInt64
        side_values = [] of String
        low_cardinality = [] of String
        variants = [] of (String | UInt64 | Nil)
        table.scan_typed(batch_rows: 2) do |batch|
          seq_rows.concat(batch.array_tuple_rows_for("seq"))
          map_rows.concat(batch.map_tuple_rows_for("mapped"))
          simple_rows.concat(batch.map_uint64_nullable_uint64s_for("simple"))
          lookup_rows.concat(batch.map_string_array_nullable_uint64s_for("lookup"))
          tuples.concat(batch.tuple_rows_for("tup"))
          u_values.concat(batch.values_for("u"))
          side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
          low_cardinality.concat(batch.low_cardinality_strings_for("lc").map { |value| String.new(value.to_slice) })
          variants.concat(batch.variant_string_uint64_for("v"))
          nil
        end

        u_values.should eq([9101_u64, 9102_u64, 9103_u64, 9104_u64, 9105_u64, 9106_u64, 9107_u64, 9108_u64])
        side_values.should eq(["side-0", "side-1", "mark-1\0mid", "π-snow-雪", "side-4", "nul\0and-尾", "side-6", "tail-✓"])
        seq_rows.map(&.size).should eq([0, 0, 2, 0, 0, 0, 1, 2])
        seq_rows[2][0].tuple("details")["note"].should eq("a\0b")
        seq_rows[2][1].tuple("details")["note"].should be_nil
        seq_rows[6][0].tuple("details").value_as("score", UInt32).should eq(61_u32)
        seq_rows[7][1]["id"].should eq(1702_u64)
        map_rows.map(&.size).should eq([0, 0, 3, 0, 0, 0, 1, 2])
        map_rows[2].key_at(0).should eq("dup")
        map_rows[2].key_at(1).should eq("dup")
        map_rows[2].key_at(2).should eq("雪")
        map_rows[2].value_at(0).tuple("meta").value_as("id", UInt64).should eq(2201_u64)
        map_rows[2].value_at(1).tuple("meta")["note"].should eq("m\0")
        map_rows[7].key_at(0).should eq("end")
        map_rows[7].key_at(1).should eq("end")
        simple_rows.should eq([
          [{1_u64, nil}] of Tuple(UInt64, UInt64?), [] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?), [{3_u64, 3003_u64}, {3_u64, 3004_u64}] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?), [{5_u64, 5005_u64}] of Tuple(UInt64, UInt64?),
          [] of Tuple(UInt64, UInt64?), [{7_u64, nil}] of Tuple(UInt64, UInt64?),
        ])
        lookup_rows[1].should eq([{"one", [nil, 9202_u64]}])
        lookup_rows[3].should eq([{"empty", [] of UInt64?}, {"dup", [nil, 9401_u64]}])
        lookup_rows[6].should eq([{"π", [9606_u64, nil]}])
        tuples.map { |row| {row.value_as("n", UInt64), row.value_as("s", String)} }.should eq([
          {3101_u64, "tuple-0"}, {3102_u64, "tuple-1"}, {3103_u64, "tuple-2\0λ"},
          {3104_u64, "雪-tuple-3"}, {3105_u64, "tuple-4"}, {3106_u64, "nul\0five"},
          {3107_u64, "tuple-6"}, {3108_u64, "tail-α"},
        ])
        low_cardinality.should eq(["dup", "red", "dup", "", "blue", "dup", "blue", "tail"])
        variants.should eq(["variant-0", 4202_u64, nil, "v\0three", 4205_u64, "尾", 4207_u64, nil])

        window_seq = [] of CrystalClick::WideArrayTupleRow
        window_maps = [] of CrystalClick::WideMapTupleRow
        table.scan_typed_window(2_u64, 4) do |batch|
          window_seq.concat(batch.array_tuple_rows_for("seq"))
          window_maps.concat(batch.map_tuple_rows_for("mapped"))
          nil
        end
        window_seq.map(&.size).should eq([2, 0, 0, 0])
        window_seq[0][0]["id"].should eq(1201_u64)
        window_maps.map(&.size).should eq([3, 0, 0, 0])
        window_maps[0].key_at(0).should eq("dup")
        window_maps[0].key_at(1).should eq("dup")

        eof_callbacks = 0
        table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
        eof_callbacks.should eq(0)
      end
    end

    it "retains typed offline materialization at exact String/Tuple budgets and rejects one-less limits" do
      w261_with_stock_part(stock_part) do |part|
        offline = w261_offline_table(part)
        seq_budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS["seq"]
        seq_values = offline["seq"].values(
          max_rows: 8_u64,
          max_string_bytes: seq_budget[:string_bytes],
          max_tuple_cells: seq_budget[:tuple_cells],
        )
        seq_rows = seq_values.map(&.as(CrystalClick::WideArrayTupleRow))
        seq_rows.map(&.size).should eq([0, 0, 2, 0, 0, 0, 1, 2])
        seq_rows[2][1].tuple("details")["note"].should be_nil
        expect_raises(CrystalClick::BoundsError) do
          offline["seq"].values(
            max_rows: 8_u64,
            max_string_bytes: seq_budget[:string_bytes] - 1_u64,
            max_tuple_cells: seq_budget[:tuple_cells],
          )
        end
        expect_raises(CrystalClick::BoundsError) do
          offline["seq"].values(
            max_rows: 8_u64,
            max_string_bytes: seq_budget[:string_bytes],
            max_tuple_cells: seq_budget[:tuple_cells] - 1_u64,
          )
        end

        map_budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS["mapped"]
        map_values = offline["mapped"].values(
          max_rows: 8_u64,
          max_string_bytes: map_budget[:string_bytes],
          max_tuple_cells: map_budget[:tuple_cells],
        )
        map_rows = map_values.map(&.as(CrystalClick::WideMapTupleRow))
        map_rows.map(&.size).should eq([0, 0, 3, 0, 0, 0, 1, 2])
        map_rows[2].key_at(0).should eq("dup")
        map_rows[2].key_at(1).should eq("dup")
        expect_raises(CrystalClick::BoundsError) do
          offline["mapped"].values(
            max_rows: 8_u64,
            max_string_bytes: map_budget[:string_bytes] - 1_u64,
            max_tuple_cells: map_budget[:tuple_cells],
          )
        end
        expect_raises(CrystalClick::BoundsError) do
          offline["mapped"].values(
            max_rows: 8_u64,
            max_string_bytes: map_budget[:string_bytes],
            max_tuple_cells: map_budget[:tuple_cells] - 1_u64,
          )
        end
      end
    end

    it "retains sparse Default metadata proof for non-key siblings, including the actual recursive Tuple sibling" do
      w261_with_stock_part(stock_part) do |part|
        tuple_children = [w261_info, w261_info] of JSON::Any
        tuple_children[0].as_h["exact_num_defaults"] = JSON::Any.new(true)
        tuple_children[1].as_h["exact_num_defaults"] = JSON::Any.new(false)
        records = [
          w261_info("seq"),
          w261_info("mapped"),
          w261_info("side"),
          w261_info("u"),
          w261_info("tup", tuple_children),
        ] of JSON::Any
        records.each { |record| record.as_h["exact_num_defaults"] = JSON::Any.new(true) }
        w261_write_records(part, records)

        seq = CrystalClick::WidePart.open_typed(part, "seq")
        seq.read_array_tuple_mark_range("seq", 1, 1).row(0)[0]["id"].should eq(1201_u64)
        mapped = CrystalClick::WidePart.open_typed(part, "mapped")
        mapped.read_map_tuple_mark_range("mapped", 1, 1).row(0).key_at(0).should eq("dup")
        simple = CrystalClick::WidePart.open_typed(part, "simple")
        simple.read_map_uint64_nullable_uint64_mark_range("simple", 0, 1).size.should eq(2)
        lookup = CrystalClick::WidePart.open_typed(part, "lookup")
        lookup.read_map_string_array_nullable_uint64_mark_range("lookup", 0, 1).size.should eq(2)
      end
    end

    it "falls back only on false proof and keeps malformed or corrupt metadata hard failures" do
      w261_with_stock_part(stock_part) do |part|
        array_unproven = JSON.parse(File.read(File.join(part, "serialization.json")))
        array_unproven.as_h["propagate_types_serialization_versions_to_nested_types"] = JSON::Any.new(false)
        w261_write_serialization(part, array_unproven)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "seq")
        end
      end

      w261_with_stock_part(stock_part) do |part|
        map_unproven = JSON.parse(File.read(File.join(part, "serialization.json")))
        versions = {"string" => JSON::Any.new(1_i64), "map" => JSON::Any.new(1_i64)} of String => JSON::Any
        map_unproven.as_h["types_serialization_versions"] = JSON::Any.new(versions)
        w261_write_serialization(part, map_unproven)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "mapped")
        end
      end

      w261_with_stock_part(stock_part) do |part|
        records = [w261_info("u")] of JSON::Any
        records[0].as_h["num_rows"] = JSON::Any.new(7_i64)
        w261_write_records(part, records)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(part, "seq")
        end
      end

      w261_with_stock_part(stock_part) do |part|
        File.write(File.join(part, "serialization.json"), "{not-json")
        CrystalClick::WidePartWriter.w261_refresh_checksums(part)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(part, "mapped")
        end
      end
    end

    it "hard-fails malformed shared Default metadata through every affected direct reader" do
      {"duplicate", "unmapped", "negative-defaults", "defaults-exceed-rows", "wrong-exact-flag",
       "bad-version-with-false-proof", "bad-type-version-with-false-proof"}.each do |mutation|
        w261_with_stock_part(stock_part) do |part|
          records = case mutation
                    when "duplicate"
                      [w261_info("u"), w261_info("u")] of JSON::Any
                    when "unmapped"
                      [w261_info("not-in-columns")] of JSON::Any
                    else
                      record = w261_info("u")
                      case mutation
                      when "negative-defaults"
                        record.as_h["num_defaults"] = JSON::Any.new(-1_i64)
                      when "defaults-exceed-rows"
                        record.as_h["num_defaults"] = JSON::Any.new(9_i64)
                      when "wrong-exact-flag"
                        record.as_h["exact_num_defaults"] = JSON::Any.new(1_i64)
                      end
                      [record] of JSON::Any
                    end
          w261_write_records(part, records)

          if mutation == "bad-version-with-false-proof" || mutation == "bad-type-version-with-false-proof"
            info = JSON.parse(File.read(File.join(part, "serialization.json")))
            info.as_h["propagate_types_serialization_versions_to_nested_types"] = JSON::Any.new(false)
            if mutation == "bad-version-with-false-proof"
              info.as_h["version"] = JSON::Any.new("one")
            else
              info.as_h["types_serialization_versions"] = JSON::Any.new(
                {"string" => JSON::Any.new("1")} of String => JSON::Any
              )
            end
            w261_write_serialization(part, info)
          end

          {"seq", "mapped", "simple", "lookup"}.each do |column|
            expect_raises(CrystalClick::CorruptPartError) do
              CrystalClick::WidePart.open_typed(part, column)
            end
          end
        end
      end
    end

    it "does not treat malformed primitive-key subcolumns as a common proof" do
      w261_with_stock_part(stock_part) do |part|
        key = w261_info("pk", [w261_info] of JSON::Any)
        w261_write_records(part, [key] of JSON::Any)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "seq")
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "mapped")
        end
      end
    end

    it "matches selected stream identity independent of roster order and rejects missing, duplicate, or extra streams" do
      {"seq", "mapped", "simple", "lookup"}.each do |column|
        w261_with_stock_part(stock_part) do |part|
          w261_rewrite_column_roster(part, column)
          reader = CrystalClick::WidePart.open_typed(part, column)
          case column
          when "seq"
            reader.read_array_tuple_mark_range(column, 0, reader.mark_count).row_sizes.should eq([0_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64, 1_u64, 2_u64])
          when "mapped"
            reader.read_map_tuple_mark_range(column, 0, reader.mark_count).row_sizes.should eq([0_u64, 0_u64, 3_u64, 0_u64, 0_u64, 0_u64, 1_u64, 2_u64])
          when "simple"
            reader.read_map_uint64_nullable_uint64_mark_range(column, 0, reader.mark_count).size.should eq(8)
          when "lookup"
            reader.read_map_string_array_nullable_uint64_mark_range(column, 0, reader.mark_count).size.should eq(8)
          end
        end
      end

      {"seq", "mapped", "simple", "lookup"}.each do |column|
        w261_with_stock_part(stock_part) do |part|
          w261_rewrite_column_roster(part, column, :missing)
          expect_raises(CrystalClick::UnsupportedFormatError) do
            CrystalClick::WidePart.open_typed(part, column)
          end
        end
      end

      {"seq", "mapped", "simple", "lookup"}.each do |column|
        {:duplicate, :extra}.each do |mutation|
          w261_with_stock_part(stock_part) do |part|
            w261_rewrite_column_roster(part, column, mutation)
            expect_raises(CrystalClick::UnsupportedFormatError) do
              CrystalClick::WidePart.open_typed(part, column)
            end
          end
        end
      end
    end

    it "uses escaped sibling identity, not a plain or substituted stream name" do
      {"seq", "mapped", "simple", "lookup"}.each do |column|
        w261_with_stock_part(stock_part) do |part|
          w261_rename_uint64_sibling(part, "u", "u.special")
          reader = CrystalClick::WidePart.open_typed(part, column)
          case column
          when "seq"
            reader.read_array_tuple_mark_range(column, 1, 1).row(0)[0]["id"].should eq(1201_u64)
          when "mapped"
            reader.read_map_tuple_mark_range(column, 1, 1).row(0).key_at(0).should eq("dup")
          when "simple"
            reader.read_map_uint64_nullable_uint64_mark_range(column, 0, 1).size.should eq(2)
          when "lookup"
            reader.read_map_string_array_nullable_uint64_mark_range(column, 0, 1).size.should eq(2)
          end
        end

        w261_with_stock_part(stock_part) do |part|
          w261_rename_uint64_sibling(part, "u", "u.special", wrong_stream: true)
          expect_raises(CrystalClick::UnsupportedFormatError) do
            CrystalClick::WidePart.open_typed(part, column)
          end
        end
      end
    end

    it "preflights Array and Map flattened cardinality corruption before callbacks" do
      {"seq", "mapped"}.each do |column|
        w261_with_stock_part(stock_part) do |part|
          w261_corrupt_mark_rows(part, "#{column}.size0", 1)
          callbacks = [] of Int32
          expect_raises(CrystalClick::CorruptPartError) do
            reader = CrystalClick::WidePart.open_typed(part, column)
            if column == "seq"
              reader.each_array_tuple_mark_range(column, 0, reader.mark_count) do |_rows, mark_index|
                callbacks << mark_index
                nil
              end
            else
              reader.each_map_tuple_mark_range(column, 0, reader.mark_count) do |_rows, mark_index|
                callbacks << mark_index
                nil
              end
            end
          end
          callbacks.should be_empty
        end
      end
    end

    it "preflights late numeric child mark-coordinate corruption before full and suffix callbacks" do
      cases = [
        {"seq", "seq%2Edetails%2Escore", 4_u64},
        {"mapped", "mapped%2Evalues%2Emeta%2Eid", 8_u64},
      ]
      ranges = [
        {0, WideRaggedSelectedMetadataW261Fixture::MARK_ROW_COUNTS.size},
        {2, 2},
      ]

      cases.each do |example|
        column = example[0]
        stream_name = example[1]
        element_width = example[2]
        ranges.each do |range|
          first_mark = range[0]
          mark_count = range[1]
          w261_with_stock_part(stock_part) do |part|
            # Mark 3 is the final data mark and contains the late Array or Map
            # elements. Change only its decompressed coordinate by one typed
            # child element; preserve compressed-frame and row coordinates.
            previous, changed = w261_corrupt_mark_decompressed_offset(
              part,
              stream_name,
              WideRaggedSelectedMetadataW261Fixture::MARK_ROW_COUNTS.size - 1,
              element_width
            )
            changed.should eq(previous + element_width)

            callbacks = [] of Int32
            expect_raises(CrystalClick::CorruptPartError) do
              reader = CrystalClick::WidePart.open_typed(part, column)
              if column == "seq"
                reader.each_array_tuple_mark_range(column, first_mark, mark_count) do |_data, mark_index|
                  callbacks << mark_index
                  nil
                end
              else
                reader.each_map_tuple_mark_range(column, first_mark, mark_count) do |_data, mark_index|
                  callbacks << mark_index
                  nil
                end
              end
            end
            callbacks.should be_empty
          end
        end
      end
    end

    it "accepts exact direct materialization charges and rejects one-less limits" do
      w261_with_stock_part(stock_part) do |part|
        reader = CrystalClick::WidePart.open_typed(part, "seq")
        wide_limit = CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES
        seq_charge = reader.array_tuple_mark_range_materialization_charge("seq", 0, reader.mark_count, wide_limit)
        reader.read_array_tuple_mark_range("seq", 0, reader.mark_count, seq_charge).row_count.should eq(8)
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_array_tuple_mark_range("seq", 0, reader.mark_count, seq_charge - 1_u64)
        end

        map_reader = CrystalClick::WidePart.open_typed(part, "mapped")
        map_charge = map_reader.map_tuple_mark_range_materialization_charge("mapped", 0, map_reader.mark_count, wide_limit)
        map_reader.read_map_tuple_mark_range("mapped", 0, map_reader.mark_count, map_charge).row_count.should eq(8)
        expect_raises(CrystalClick::CorruptPartError) do
          map_reader.read_map_tuple_mark_range("mapped", 0, map_reader.mark_count, map_charge - 1_u64)
        end
      end
    end
  end
end
