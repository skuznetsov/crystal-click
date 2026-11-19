require "./spec_helper"

private def w263_direct_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(64, 100_000, 1_000_000, 64 * 1024 * 1024)
end

private def w263_direct_typed_row(pairs : Array(Tuple(String, CrystalClick::BinaryValue))) : CrystalClick::ObjectSharedMapRow
  entries = pairs.map do |pair|
    CrystalClick::ObjectSharedMapEntry.new(pair[0].to_slice, pair[1])
  end
  entries.sort! do |left, right|
    CrystalClick::ObjectSharedChunkStructure.compare_paths(
      String.build(left.path_byte_size) { |io| left.path_byte_size.times { |index| io.write_byte(left.path_byte_at(index)) } },
      String.build(right.path_byte_size) { |io| right.path_byte_size.times { |index| io.write_byte(right.path_byte_at(index)) } },
    )
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w263_direct_row(pairs : Array(Tuple(String, String))) : CrystalClick::ObjectSharedMapRow
  values = pairs.map do |pair|
    {pair[0], CrystalClick::BinaryValue.string(pair[1])}
  end
  w263_direct_typed_row(values)
end

private def w263_direct_batch(
  buckets : Array(CrystalClick::ObjectSharedPhysicalChunk),
  row_count : Int32,
) : CrystalClick::CompactJsonColumnarBatch
  paths = [] of String
  buckets.each do |bucket|
    bucket.path_count.times { |index| paths << bucket.path_at(index).name }
  end
  batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
    paths,
    [] of String,
    {} of String => CrystalClick::BinaryDataType,
    row_count,
    1_000_u64,
  )
  batch.begin_mark!(0, "part", "/part", 0, 0_u64, 0_u64, 0_u64, row_count.to_u64)
  batch
end

private def w263_direct_text(value : CrystalClick::BinaryValue) : String
  String.build(value.byte_size) do |io|
    value.byte_size.times { |index| io.write_byte(value.byte_at(index)) }
  end
end

private def w263_decode_into_columns(
  buckets : Array(CrystalClick::ObjectSharedPhysicalChunk),
  copy : CrystalClick::ObjectSharedCopyStreams,
  row_count : Int32,
) : CrystalClick::CompactJsonColumnarBatch
  batch = w263_direct_batch(buckets, row_count)
  decoded_rows = CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
    buckets,
    copy,
    CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
    batch,
    0_i32,
  ) { |_path| }
  decoded_rows.should eq(row_count.to_u64)
  batch
end

private def w263_decode_into_columns_with_limits(
  buckets : Array(CrystalClick::ObjectSharedPhysicalChunk),
  copy : CrystalClick::ObjectSharedCopyStreams,
  row_count : Int32,
  limits : CrystalClick::BinaryCodecLimits,
) : Tuple(CrystalClick::CompactJsonColumnarBatch, CrystalClick::BinaryCodecBudget)
  batch = w263_direct_batch(buckets, row_count)
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  decoded_rows = CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
    buckets,
    copy,
    budget,
    batch,
    0_i32,
  ) { |_path| }
  decoded_rows.should eq(row_count.to_u64)
  {batch, budget}
end

describe "W263 direct SharedData Copy-to-column decode" do
  it "appends sparse Copy values directly and verifies their per-path Data rows" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}, {"direct-b", "b0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-a", "a1"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b2"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )

    batch = w263_decode_into_columns(encoded.buckets, encoded.copy_streams, 3)
    path_a = batch.column_for("direct-a").not_nil!
    path_b = batch.column_for("direct-b").not_nil!
    w263_direct_text(path_a.value_at(0).not_nil!).should eq("a0")
    w263_direct_text(path_a.value_at(1).not_nil!).should eq("a1")
    path_a.value_at(2).should be_nil
    w263_direct_text(path_b.value_at(0).not_nil!).should eq("b0")
    path_b.value_at(1).should be_nil
    w263_direct_text(path_b.value_at(2).not_nil!).should eq("b2")
  end

  it "preserves exact empty and arbitrary String bytes across short and long VarUInt frames" do
    values = [
      Bytes.empty,
      Bytes[0xff_u8, 0x00_u8, 0x80_u8, 0xc3_u8, 0x28_u8],
      Bytes.new(125) { 0x31_u8 },
      Bytes.new(126) { 0x32_u8 },
      Bytes.new(127) { 0x33_u8 },
      Bytes.new(128) { 0x34_u8 },
    ] of Bytes
    string_type = CrystalClick::BinaryDataType.primitive("String")
    rows = values.map do |bytes|
      w263_direct_typed_row([
        {"direct-string", CrystalClick::BinaryValue.string(string_type, bytes)},
      ] of Tuple(String, CrystalClick::BinaryValue))
    end.to_a
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )

    # One descriptor byte plus the String length VarUInt and bytes makes the
    # 125/126-byte String envelopes exactly 127/128 bytes. The final pair also
    # crosses the inner String-length VarUInt boundary at 127/128 bytes.
    lane = encoded.copy_streams.values
    limits = w263_direct_limits
    context = CrystalClick::BinaryCodecContext.new(
      limits,
      lane,
      false,
      CrystalClick::BinaryCodecBudget.new(limits),
      false,
    )
    [2_u64, 7_u64, 127_u64, 128_u64, 129_u64, 131_u64].each_with_index do |expected_size, index|
      prefix_offset = context.input_offset
      envelope_size = context.read_var_uint
      envelope_size.should eq(expected_size)
      (context.input_offset - prefix_offset).should eq(index < 3 ? 1 : 2)
      context.read_slice(envelope_size)
    end
    context.ensure_consumed

    batch = w263_decode_into_columns(encoded.buckets, encoded.copy_streams, values.size)
    column = batch.column_for("direct-string").not_nil!
    values.each_with_index do |bytes, row|
      column.with_cell_at(row) do |cell|
        borrowed = cell.borrowed_string_bytes?
        borrowed.should_not be_nil
        borrowed.not_nil!.should eq(bytes)
        if row == 1
          expect_raises(Exception, "Can't write to read-only Slice") do
            borrowed.not_nil![0] = 0x42_u8
          end
          borrowed.not_nil!.should eq(bytes)
        end
      end.should be_true
      column.value_at(row).not_nil!.bytes.should eq(bytes)
    end
  end

  it "keeps a retained String BinaryValue stable when its batch is reset and reused" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    first = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [w263_direct_typed_row([
        {"direct-retained", CrystalClick::BinaryValue.string(string_type, Bytes[0x00_u8, 0xff_u8, 0x61_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue))] of CrystalClick::ObjectSharedMapRow,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    batch = w263_direct_batch(first.buckets, 1)
    CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
      first.buckets,
      first.copy_streams,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
      batch,
      0_i32,
    ) { |_path| }
    retained = batch.column_for("direct-retained").not_nil!.value_at(0).not_nil!
    retained.bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x61_u8])

    second = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      [w263_direct_typed_row([
        {"direct-retained", CrystalClick::BinaryValue.string(string_type, Bytes[0x62_u8, 0x00_u8, 0x63_u8, 0xfe_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue))] of CrystalClick::ObjectSharedMapRow,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    batch.reset!
    batch.begin_mark!(0, "part", "/part", 1, 0_u64, 1_u64, 1_u64, 1_u64)
    CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
      second.buckets,
      second.copy_streams,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
      batch,
      0_i32,
    ) { |_path| }

    retained.bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x61_u8])
    batch.column_for("direct-retained").not_nil!.value_at(0).not_nil!.bytes.should eq(
      Bytes[0x62_u8, 0x00_u8, 0x63_u8, 0xfe_u8],
    )
  end

  it "preserves mixed String, non-String, and absent values for one Copy path" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    rows = [
      w263_direct_typed_row([
        {"direct-mixed", CrystalClick::BinaryValue.string(string_type, Bytes[0x00_u8, 0xff_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([
        {"direct-mixed", CrystalClick::BinaryValue.uint64(91_u64)},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([
        {"direct-mixed", CrystalClick::BinaryValue.string(string_type, Bytes.empty)},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )

    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    dynamic_structure = CrystalClick::DynamicStructure.new(
      [string_type, uint64_type] of CrystalClick::BinaryDataType,
    )
    dynamic_rows = [
      CrystalClick::BinaryValue.dynamic(
        dynamic_type,
        CrystalClick::BinaryValue.string(string_type, Bytes[0x00_u8, 0xff_u8]),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.uint64(91_u64)),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string(string_type, Bytes.empty)),
      CrystalClick::BinaryValue.dynamic(dynamic_type),
    ] of CrystalClick::BinaryValue
    direct_streams = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      dynamic_type,
      {"root" => dynamic_structure} of String => CrystalClick::DynamicStructure,
      dynamic_rows,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    direct_event_names = direct_streams.events.map(&.name)
    direct_event_names.any? { |name| name.ends_with?(".String.size") }.should be_true
    direct_event_names.any? { |name| name.ends_with?(".String") }.should be_true
    direct_event_names.any? { |name| name.ends_with?(".UInt64") }.should be_true
    original_bucket = encoded.bucket_at(0)
    original_path = original_bucket.path_at(0)
    direct_buckets = [
      CrystalClick::ObjectSharedPhysicalChunk.new(
        original_bucket.row_count,
        [CrystalClick::ObjectSharedPhysicalPath.new(original_path.name, direct_streams)] of CrystalClick::ObjectSharedPhysicalPath,
      ),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    batch, read_budget = w263_decode_into_columns_with_limits(
      direct_buckets,
      encoded.copy_streams,
      4,
      w263_direct_limits,
    )
    {read_budget.node_count, read_budget.element_count, read_budget.wire_byte_count}.should eq(
      {92_i64, 1_099_i64, 2_391_i64},
    )

    column = batch.column_for("direct-mixed").not_nil!
    column.value_at(0).not_nil!.bytes.should eq(Bytes[0x00_u8, 0xff_u8])
    column.value_at(1).not_nil!.as_uint64.should eq(91_u64)
    column.value_at(2).not_nil!.bytes.should eq(Bytes.empty)
    column.value_at(3).should be_nil
    column.with_cell_at(0) do |cell|
      borrowed = cell.borrowed_string_bytes?
      borrowed.should_not be_nil
      borrowed.not_nil!.should eq(Bytes[0x00_u8, 0xff_u8])
    end.should be_true
    column.with_cell_at(1) do |cell|
      cell.borrowed_string_bytes?.should be_nil
    end.should be_true
    column.with_cell_at(2) do |cell|
      borrowed = cell.borrowed_string_bytes?
      borrowed.should_not be_nil
      borrowed.not_nil!.should eq(Bytes.empty)
    end.should be_true
    column.with_cell_at(3) do |_cell|
      fail "an absent Copy path row must not have a retained cell"
    end.should be_false
  end

  it "preserves mixed String, non-String, and absent values through SharedVariant" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    rows = [
      w263_direct_typed_row([
        {"direct-shared-mixed", CrystalClick::BinaryValue.string(string_type, Bytes[0x00_u8, 0xff_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([
        {"direct-shared-mixed", CrystalClick::BinaryValue.uint64(91_u64)},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([
        {"direct-shared-mixed", CrystalClick::BinaryValue.string(string_type, Bytes.empty)},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )

    batch = w263_decode_into_columns(encoded.buckets, encoded.copy_streams, 4)
    column = batch.column_for("direct-shared-mixed").not_nil!
    column.value_at(0).not_nil!.bytes.should eq(Bytes[0x00_u8, 0xff_u8])
    column.value_at(1).not_nil!.as_uint64.should eq(91_u64)
    column.value_at(2).not_nil!.bytes.should eq(Bytes.empty)
    column.value_at(3).should be_nil
    column.with_cell_at(1) do |cell|
      cell.borrowed_string_bytes?.should be_nil
    end.should be_true
    column.with_cell_at(3) do |_cell|
      fail "an absent SharedVariant path row must not have a retained cell"
    end.should be_false
  end

  it "honors exact and one-byte-short Copy decode byte limits" do
    rows = [w263_direct_row([{"direct-limited", "bounded"}] of Tuple(String, String))] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    copy = encoded.copy_streams
    _batch, unrestricted_budget = w263_decode_into_columns_with_limits(
      encoded.buckets,
      copy,
      1,
      w263_direct_limits,
    )
    required_bytes = unrestricted_budget.wire_byte_count.to_i
    exact_limits = CrystalClick::BinaryCodecLimits.new(64, 100_000, 1_000_000, required_bytes)
    exact_batch, exact_budget = w263_decode_into_columns_with_limits(encoded.buckets, copy, 1, exact_limits)
    exact_batch.row_count.should eq(1)
    exact_budget.wire_byte_count.should eq(required_bytes.to_i64)

    short_limits = CrystalClick::BinaryCodecLimits.new(64, 100_000, 1_000_000, required_bytes - 1)
    expect_raises(CrystalClick::CorruptPartError, "binary codec byte limit exceeded") do
      w263_decode_into_columns_with_limits(encoded.buckets, copy, 1, short_limits)
    end
  end

  it "rejects malformed exact String envelopes in the actual SharedVariant Data lane" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    rows = [w263_direct_typed_row([
      {"direct-malformed", CrystalClick::BinaryValue.string(string_type, Bytes[0x41_u8, 0x42_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue))] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    bucket = encoded.bucket_at(0)
    path = bucket.path_at(0)
    original_streams = path.streams
    events = original_streams.events
    data_event_index = events.index { |event| event.name == ".SharedVariant" }.not_nil!
    data_start = events[data_event_index].relative_offset.to_i
    data_end = if data_event_index + 1 < events.size
                 events[data_event_index + 1].relative_offset.to_i
               else
                 original_streams.data_size
               end
    envelope_size = data_end - data_start
    envelope_size.should eq(4)
    original_data = original_streams.data
    original_data[data_start].should eq(CrystalClick::BinaryDataType::TAG_STRING)
    original_data[data_start + 1].should eq(0x02_u8)

    malformed_envelopes = [
      {Bytes[CrystalClick::BinaryDataType::TAG_STRING, 0x81_u8, 0x00_u8, 0x42_u8],
       "binary codec VarUInt is nonminimal"},
      {Bytes[CrystalClick::BinaryDataType::TAG_STRING, 0x01_u8, 0x41_u8, 0x42_u8],
       "binary codec input has trailing bytes"},
    ] of Tuple(Bytes, String)

    malformed_envelopes.each do |envelope, error_message|
      mutated_data = original_data.dup
      mutated_data[data_start, envelope.size].copy_from(envelope)
      mutated_data.should_not eq(original_data)
      mutated_streams = CrystalClick::ObjectSharedPathStreams.new(mutated_data, events)
      mutated_buckets = [
        CrystalClick::ObjectSharedPhysicalChunk.new(
          bucket.row_count,
          [CrystalClick::ObjectSharedPhysicalPath.new(path.name, mutated_streams)] of CrystalClick::ObjectSharedPhysicalPath,
        ),
      ] of CrystalClick::ObjectSharedPhysicalChunk
      batch = w263_direct_batch(mutated_buckets, 1)
      expect_raises(CrystalClick::CorruptPartError, error_message) do
        CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
          mutated_buckets,
          encoded.copy_streams,
          CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
          batch,
          0_i32,
        ) { |_path| }
      end
    end
  end

  it "bounds an inner String VarUInt to its Copy envelope despite following bytes" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    rows = [
      w263_direct_typed_row([
        {"direct-bounded", CrystalClick::BinaryValue.string(string_type, Bytes[0x61_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue)),
      w263_direct_typed_row([
        {"direct-bounded", CrystalClick::BinaryValue.string(string_type, Bytes.new(128) { 0x4d_u8 })},
      ] of Tuple(String, CrystalClick::BinaryValue)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    values = encoded.copy_streams.values
    # Shrink row zero's envelope to descriptor + one VarUInt byte, then make
    # that byte a continuation. A buggy unbounded reader could consume the
    # following payload and the long second envelope as the missing VarUInt.
    values[0] = 2_u8
    values[2] = 0x80_u8
    values[3] = 0x01_u8
    copy = CrystalClick::ObjectSharedCopyStreams.new(
      encoded.copy_streams.sizes,
      encoded.copy_streams.indexes,
      values,
    )
    batch = w263_direct_batch(encoded.buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "binary codec input is truncated") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        encoded.buckets,
        copy,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a valid same-path Copy String whose valid Data row has a different type" do
    string_rows = [w263_direct_typed_row([
      {"direct-type", CrystalClick::BinaryValue.string("text")},
    ] of Tuple(String, CrystalClick::BinaryValue))] of CrystalClick::ObjectSharedMapRow
    numeric_rows = [w263_direct_typed_row([
      {"direct-type", CrystalClick::BinaryValue.uint64(42_u64)},
    ] of Tuple(String, CrystalClick::BinaryValue))] of CrystalClick::ObjectSharedMapRow
    string_encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      string_rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    numeric_encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      numeric_rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    batch = w263_direct_batch(numeric_encoded.buckets, 1)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy value disagrees with its per-path Dynamic row") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        numeric_encoded.buckets,
        string_encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a repeated dictionary index in one Copy row" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}, {"direct-b", "b0"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    indexes = encoded.copy_streams.indexes
    indexes[1] = indexes[0]
    copy = CrystalClick::ObjectSharedCopyStreams.new(
      encoded.copy_streams.sizes,
      indexes,
      encoded.copy_streams.values,
    )
    buckets = encoded.buckets
    batch = w263_direct_batch(buckets, 1)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy row indexes are not in byte-path order") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        buckets,
        copy,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects an unreferenced dictionary entry after a valid-width cross-row index change" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b1"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    indexes = encoded.copy_streams.indexes
    indexes[1] = indexes[0]
    copy = CrystalClick::ObjectSharedCopyStreams.new(
      encoded.copy_streams.sizes,
      indexes,
      encoded.copy_streams.values,
    )
    buckets = encoded.buckets
    batch = w263_direct_batch(buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy dictionary contains an unreferenced path") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        buckets,
        copy,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a per-path mismatch when both Data streams remain valid" do
    rows = [
      w263_direct_row([{"direct-a", "aa"}, {"direct-b", "bb"}] of Tuple(String, String)),
      w263_direct_row([{"direct-a", "cc"}, {"direct-b", "dd"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    bucket = encoded.bucket_at(0)
    first = bucket.path_at(0)
    second = bucket.path_at(1)
    swapped = [
      CrystalClick::ObjectSharedPhysicalPath.new(first.name, second.streams),
      CrystalClick::ObjectSharedPhysicalPath.new(second.name, first.streams),
    ] of CrystalClick::ObjectSharedPhysicalPath
    mutated_buckets = [
      CrystalClick::ObjectSharedPhysicalChunk.new(bucket.row_count, swapped),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    batch = w263_direct_batch(mutated_buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "Object shared Copy value disagrees with its per-path Dynamic row") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        mutated_buckets,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end

  it "rejects a non-NULL Data row where the Copy roster has no path entry" do
    rows = [
      w263_direct_row([{"direct-a", "a0"}] of Tuple(String, String)),
      w263_direct_row([{"direct-b", "b1"}] of Tuple(String, String)),
    ] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      rows,
      1,
      CrystalClick::BinaryCodecBudget.new(w263_direct_limits, true),
    )
    bucket = encoded.bucket_at(0)
    first = bucket.path_at(0)
    second = bucket.path_at(1)
    shifted = [
      CrystalClick::ObjectSharedPhysicalPath.new(first.name, first.streams),
      CrystalClick::ObjectSharedPhysicalPath.new(second.name, first.streams),
    ] of CrystalClick::ObjectSharedPhysicalPath
    mutated_buckets = [
      CrystalClick::ObjectSharedPhysicalChunk.new(bucket.row_count, shifted),
    ] of CrystalClick::ObjectSharedPhysicalChunk
    batch = w263_direct_batch(mutated_buckets, 2)

    expect_raises(CrystalClick::CorruptPartError, "absent Object shared path has a non-NULL Dynamic row") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode_into_columns(
        mutated_buckets,
        encoded.copy_streams,
        CrystalClick::BinaryCodecBudget.new(w263_direct_limits),
        batch,
        0_i32,
      ) { |_path| }
    end
  end
end
