require "./spec_helper"
require "file_utils"
require "../scripts/support/static_binary_bulk_table_w247_fixture"

private def w247_candidate(path : String, row_count : UInt64 = 5_u64) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, row_count)
end

private def w247_offline_table(
  path : String,
  row_count : UInt64 = 5_u64,
  projections : Array(CrystalClick::OfflineProjection) = [] of CrystalClick::OfflineProjection,
) : CrystalClick::OfflineTable
  columns = [CrystalClick::OfflineColumn.new("pk", "UInt64")] of CrystalClick::OfflineColumn
  StaticBinaryBulkTableW247Fixture.types.each do |name, type|
    columns << CrystalClick::OfflineColumn.new(name, type.name)
  end
  CrystalClick::OfflineTable.new(
    "events",
    "w247-static-bulk",
    "MergeTree",
    columns,
    [w247_candidate(path, row_count)] of CrystalClick::OfflinePartCandidate,
    projections: projections,
  )
end

private def w247_expect_rows!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue)) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    value.type.name.should eq(expected[index].type.name)
    StaticBinaryBulkTableW247Fixture.row_signature(value).should eq(
      StaticBinaryBulkTableW247Fixture.row_signature(expected[index])
    )
  end
end

private def w247_all_rows!(table : CrystalClick::WidePartTable, column : String) : Array(CrystalClick::BinaryValue)
  rows = [] of CrystalClick::BinaryValue
  table.scan_typed do |batch|
    rows.concat(batch.binary_bulk_values_for(column))
  end
  rows
end

describe "W247 generic static BinaryBulk table handoff" do
  it "keeps contextual and nominal-owner declarations out while admitting static Nested" do
    [
      "Dynamic(max_types=0)",
      "Array(Dynamic(max_types=0))",
      "JSON(x UInt8)",
      "AggregateFunction(sum, UInt64)",
      "Array(AggregateFunction(sum, UInt64))",
      "SimpleAggregateFunction(sum, UInt64)",
      "Nullable(SimpleAggregateFunction(sum, UInt64))",
    ].each do |declaration|
      CrystalClick::StaticBinaryBulkColumnDeclaration.parse(declaration).should be_nil
    end

    CrystalClick::StaticBinaryBulkColumnDeclaration.parse(
      "Nested(a UInt64)"
    ).not_nil!.name.should eq("Nested(a UInt64)")

    CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(
      "SimpleAggregateFunction(sum, UInt64)"
    ).should_not be_nil
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(
      "Array(AggregateFunction(sum, UInt64))"
    ).should_not be_nil
  end

  it "writes exact recursive rows and reads every mark through typed table dispatch with legacy columns" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w247-static-table-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        StaticBinaryBulkTableW247Fixture.write_part(part, profile_name).should eq(part)

        expected_columns = StaticBinaryBulkTableW247Fixture.types
        expected_columns.each do |name, type|
          File.read(File.join(part, "columns.txt")).should contain("`#{name}` #{type.name}")
        end

        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          type = expected_columns[name]
          reader = CrystalClick::BinaryBulkColumnReader.open(part, name, type)
          reader.ordinary_profile.should eq(StaticBinaryBulkTableW247Fixture.profile(profile_name))
          reader.row_count.should eq(5_u64)
          reader.mark_row_counts.should eq(StaticBinaryBulkTableW247Fixture::MARK_ROW_COUNTS)
          expected = StaticBinaryBulkTableW247Fixture.rows_for(name)
          actual = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
          w247_expect_rows!(actual, expected)
          last_mark = reader.read_marks(2, 1).flat_map { |mark| mark }
          w247_expect_rows!(last_mark, expected[4, 1])
          reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))
        end

        selected = [StaticBinaryBulkTableW247Fixture::KEY_NAME] +
                   StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS +
                   StaticBinaryBulkTableW247Fixture::STRING_COLUMNS
        CrystalClick::WidePart.supports_typed_type?(StaticBinaryBulkTableW247Fixture.variant_type.name).should be_false
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN)
        end
        table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
        table.column_types.should eq(
          [{"pk", "UInt64"}] +
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.map { |name| {name, expected_columns[name].name} } +
          StaticBinaryBulkTableW247Fixture::STRING_COLUMNS.map { |name| {name, "String"} }
        )
        table.part_mark_row_counts.should eq([StaticBinaryBulkTableW247Fixture::MARK_ROW_COUNTS])
        table.total_row_count.should eq(5_u64)

        keys = [] of UInt64
        strings0 = [] of String
        strings1 = [] of String
        observed = Hash(String, Array(CrystalClick::BinaryValue)).new do |values, name|
          values[name] = [] of CrystalClick::BinaryValue
        end
        callback_marks = [] of Int32
        table.scan_typed do |batch|
          callback_marks << batch.mark_index
          keys.concat(batch.values_for("pk"))
          strings0.concat(batch.strings_for(StaticBinaryBulkTableW247Fixture::STRING0_COLUMN))
          strings1.concat(batch.strings_for(StaticBinaryBulkTableW247Fixture::STRING1_COLUMN))
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            observed[name].concat(batch.binary_bulk_values_for(name))
          end
          if batch.mark_index == 0
            expect_raises(CrystalClick::UnsupportedFormatError) do
              batch.dynamic_bulk_values_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN)
            end
            expect_raises(CrystalClick::UnsupportedFormatError) do
              batch.binary_bulk_values_for(StaticBinaryBulkTableW247Fixture::STRING0_COLUMN)
            end
            expect_raises(CrystalClick::UnsupportedFormatError) do
              batch.strings_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN)
            end
          end
        end
        callback_marks.should eq([0, 1, 2])
        keys.should eq(StaticBinaryBulkTableW247Fixture::KEYS)
        strings0.should eq(StaticBinaryBulkTableW247Fixture.rows_for(StaticBinaryBulkTableW247Fixture::STRING0_COLUMN).map(&.as_string))
        strings1.should eq(StaticBinaryBulkTableW247Fixture.rows_for(StaticBinaryBulkTableW247Fixture::STRING1_COLUMN).map(&.as_string))
        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          w247_expect_rows!(observed[name], StaticBinaryBulkTableW247Fixture.rows_for(name))
        end

        window_keys = [] of UInt64
        window_strings = [] of String
        window_values = Hash(String, Array(CrystalClick::BinaryValue)).new do |values, name|
          values[name] = [] of CrystalClick::BinaryValue
        end
        table.scan_typed_window(4_u64, 1) do |batch|
          batch.mark_index.should eq(2)
          batch.source_row_offset.should eq(4_u64)
          window_keys.concat(batch.values_for("pk"))
          window_strings.concat(batch.strings_for(StaticBinaryBulkTableW247Fixture::STRING1_COLUMN))
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            window_values[name].concat(batch.binary_bulk_values_for(name))
          end
        end
        window_keys.should eq([5_u64])
        window_strings.should eq(["last"])
        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          w247_expect_rows!(window_values[name], StaticBinaryBulkTableW247Fixture.rows_for(name)[4, 1])
        end

        eof_callbacks = 0
        table.scan_typed_window(5_u64, 1) { |_batch| eof_callbacks += 1 }
        eof_callbacks.should eq(0)
        expect_raises(CrystalClick::BoundsError) do
          table.scan_typed_window(6_u64, 1) { |_batch| }
        end

        wrong_nominal_type = CrystalClick::BinaryDataType.primitive("String")
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::BinaryBulkColumnReader.open(
            part,
            StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN,
            wrong_nominal_type,
          )
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "keeps legacy String version zero readable and rejects unknown versions" do
    parent = File.tempname("crystal-click-w247-static-string-version-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      StaticBinaryBulkTableW247Fixture.write_part(part, "single")

      serialization_path = File.join(part, "serialization.json")
      serialization = JSON.parse(File.read(serialization_path))
      serialization["types_serialization_versions"].as_h["string"].as_i.should eq(0)

      expected = StaticBinaryBulkTableW247Fixture.rows_for(
        StaticBinaryBulkTableW247Fixture::STRING0_COLUMN
      ).map(&.as_string)
      reader = CrystalClick::WidePart.open_typed(
        part, StaticBinaryBulkTableW247Fixture::STRING0_COLUMN
      )
      reader.read_string_mark_range(
        StaticBinaryBulkTableW247Fixture::STRING0_COLUMN, 0, reader.mark_count
      ).should eq(expected)
      expected_raw_bytes = expected.reduce(0_u64) do |total, value|
        total + value.bytesize.to_u64
      end
      reader.string_mark_range_raw_bytes(
        StaticBinaryBulkTableW247Fixture::STRING0_COLUMN, 0, reader.mark_count
      ).should eq(expected_raw_bytes)
      reader.string_mark_range_raw_bytes(
        StaticBinaryBulkTableW247Fixture::STRING0_COLUMN, 2, 1
      ).should eq(expected.last.bytesize.to_u64)

      offline = w247_offline_table(part)
      expect_raises(CrystalClick::BoundsError) do
        offline[StaticBinaryBulkTableW247Fixture::STRING0_COLUMN].values(
          max_string_bytes: expected_raw_bytes - 1_u64
        )
      end

      serialization["types_serialization_versions"].as_h["string"] = JSON::Any.new(999_i64)
      File.write(serialization_path, serialization.to_json)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, StaticBinaryBulkTableW247Fixture::STRING0_COLUMN)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes the same recursive values through the offline column owner under row limits" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w247-static-offline-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        StaticBinaryBulkTableW247Fixture.write_part(part, profile_name)
        table = w247_offline_table(part)

        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          values = table[name].values(max_rows: 5_u64).map(&.as(CrystalClick::BinaryValue))
          w247_expect_rows!(values, StaticBinaryBulkTableW247Fixture.rows_for(name))
        end
        expect_raises(CrystalClick::BoundsError) do
          table[StaticBinaryBulkTableW247Fixture::ARRAY_VARIANT_COLUMN].values(max_rows: 4_u64)
        end
        expect_raises(CrystalClick::BoundsError) do
          table[StaticBinaryBulkTableW247Fixture::TUPLE_COLUMN].values(max_string_bytes: 1_u64)
        end

        stale_count_table = w247_offline_table(part, 4_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          stale_count_table[StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN].values(max_rows: 5_u64)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "scans only candidate granules and keeps an empty schedule callback-free" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w247-static-candidates-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        StaticBinaryBulkTableW247Fixture.write_part(part, profile_name)
        selected = [StaticBinaryBulkTableW247Fixture::KEY_NAME] +
                   StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS +
                   StaticBinaryBulkTableW247Fixture::STRING_COLUMNS
        table = CrystalClick::WidePartTable.open_selected_typed([part], selected)

        marks = [] of Int32
        offsets = [] of UInt64
        keys = [] of UInt64
        legacy_strings = [] of String
        values = Hash(String, Array(CrystalClick::BinaryValue)).new do |rows, name|
          rows[name] = [] of CrystalClick::BinaryValue
        end
        table.scan_typed_candidate_marks([[2_i32]]) do |batch|
          marks << batch.mark_index
          offsets << batch.source_row_offset
          keys.concat(batch.values_for(StaticBinaryBulkTableW247Fixture::KEY_NAME))
          legacy_strings.concat(batch.strings_for(StaticBinaryBulkTableW247Fixture::STRING1_COLUMN))
          StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
            values[name].concat(batch.binary_bulk_values_for(name))
          end
        end
        marks.should eq([2])
        offsets.should eq([4_u64])
        keys.should eq([5_u64])
        legacy_strings.should eq(["last"])
        StaticBinaryBulkTableW247Fixture::TARGET_COLUMNS.each do |name|
          w247_expect_rows!(values[name], StaticBinaryBulkTableW247Fixture.rows_for(name)[4, 1])
        end

        empty_callbacks = 0
        table.scan_typed_candidate_marks([[] of Int32]) { |_batch| empty_callbacks += 1 }
        empty_callbacks.should eq(0)

        invalid_callbacks = 0
        expect_raises(CrystalClick::BoundsError) do
          table.scan_typed_candidate_marks([[0_i32, 0_i32]]) { |_batch| invalid_callbacks += 1 }
        end
        invalid_callbacks.should eq(0)
        expect_raises(CrystalClick::BoundsError) do
          table.scan_typed_candidate_marks([[3_i32]]) { |_batch| invalid_callbacks += 1 }
        end
        invalid_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects a same-size malformed selected mark grid before empty-schedule callbacks" do
    parent = File.tempname("crystal-click-w247-static-mark-grid-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      StaticBinaryBulkTableW247Fixture.write_part(part, "single")

      column = StaticBinaryBulkTableW247Fixture::ARRAY_VARIANT_COLUMN
      type = StaticBinaryBulkTableW247Fixture.array_variant_type
      expected_grid = StaticBinaryBulkTableW247Fixture::MARK_ROW_COUNTS + [0_u64]
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        type,
        column,
        StaticBinaryBulkTableW247Fixture.profile("single"),
      )
      role = physical.stream_names.keys.sort.find do |candidate|
        marks = File.join(part, physical.marks_file_for(candidate, true))
        File.exists?(marks) &&
          File.size(marks) == (expected_grid.size * 24).to_i64
      end.not_nil!
      marks_path = File.join(part, physical.marks_file_for(role, true))
      original_size = File.size(marks_path)
      mark_bytes = File.read(marks_path).to_slice.dup
      mark_bytes.size.to_i64.should eq(original_size)
      mark_bytes.size.should eq(expected_grid.size * 24)

      expected_grid.each_with_index do |expected_rows, index|
        row_count_offset = index * 24 + 16
        actual_rows = 0_u64
        8.times do |byte|
          actual_rows |= mark_bytes[row_count_offset + byte].to_u64 << (byte * 8)
        end
        actual_rows.should eq(expected_rows)
      end

      # Each .mrk2 row is two UInt64 offsets followed by a UInt64 row count.
      # The final record is the zero-row EOF sentinel. Change mark 1 from two
      # rows to nine, retaining the file size and all offsets.
      row_count_offset = 1 * 24 + 16
      mark_bytes[row_count_offset] = 9_u8
      File.write(marks_path, mark_bytes)
      File.size(marks_path).should eq(original_size)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed(
          [part], [StaticBinaryBulkTableW247Fixture::KEY_NAME, column]
        )
        table.scan_typed_candidate_marks([[] of Int32]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a corrupt LC dictionary tail before callbacks on consuming scans" do
    parent = File.tempname("crystal-click-w247-static-lc-schedule-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      StaticBinaryBulkTableW247Fixture.write_part(part, "single", frame_bytes: 8)
      array_type = StaticBinaryBulkTableW247Fixture.array_variant_type
      column = StaticBinaryBulkTableW247Fixture::ARRAY_VARIANT_COLUMN
      profile = StaticBinaryBulkTableW247Fixture.profile("single")
      plan = CrystalClick::BinaryBulkTypePlan.new(
        array_type,
        profile,
        nil,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        false,
      )
      site = plan.low_cardinality_sites.first? || raise("W247 Array(Variant) fixture has no LC site")
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(array_type, column, profile)
      dictionary_path = File.join(part, physical.data_file_for(site.dictionary_role, true))

      reader = CrystalClick::BinaryBulkColumnReader.open(part, column, array_type)
      clean_first_mark = reader.read_marks(0, 1).flat_map { |mark| mark }
      w247_expect_rows!(clean_first_mark, StaticBinaryBulkTableW247Fixture.rows_for(column)[0, 2])

      table = CrystalClick::WidePartTable.open_selected_typed(
        [part], [StaticBinaryBulkTableW247Fixture::KEY_NAME, column]
      )
      bytes = File.read(dictionary_path).to_slice.dup
      raise "W247 static LC dictionary file is unexpectedly empty" if bytes.empty?
      frame_index = CrystalClick::CompressedFrameIndex.new(
        bytes,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      frame_index.frames.size.should be > 1
      tail_frame = frame_index.frames.last
      tail_frame.compressed_offset.should be > 0
      tail_frame.end_offset.should eq(bytes.size.to_i64)
      tail_frame.compressed_offset.should be < tail_frame.end_offset
      # The global LC dictionary is not mark-local; corrupt its actual final
      # compressed frame while preserving the checksum-declared file size.
      bytes[tail_frame.compressed_offset.to_i] = bytes[tail_frame.compressed_offset.to_i] ^ 0xff_u8
      File.write(dictionary_path, bytes)

      full_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed { |_batch| full_callbacks += 1 }
      end
      full_callbacks.should eq(0)

      selected_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[2_i32]]) do |_batch|
          selected_callbacks += 1
        end
      end
      selected_callbacks.should eq(0)

      # The empty candidate schedule validates the complete mark grid but
      # consumes no LC payload, so it must remain callback-free without
      # claiming checksum authentication of the dictionary bytes.
      empty_candidate_callbacks = 0
      table.scan_typed_candidate_marks([[] of Int32]) do |_batch|
        empty_candidate_callbacks += 1
      end
      empty_candidate_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads a selected projection child through its own typed part owner" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w247-static-projection-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        StaticBinaryBulkTableW247Fixture.write_part(part, profile_name)
        child = File.join(part, "by_shape.proj")
        StaticBinaryBulkTableW247Fixture.write_part(child, profile_name)

        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [part], "by_shape", [StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN]
        )
        table.column_types.should eq([{
          StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN,
          StaticBinaryBulkTableW247Fixture.variant_type.name,
        }])
        table.part_mark_row_counts.should eq([StaticBinaryBulkTableW247Fixture::MARK_ROW_COUNTS])
        w247_expect_rows!(
          w247_all_rows!(table, StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN),
          StaticBinaryBulkTableW247Fixture.rows_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN),
        )
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "routes a declared OfflineTable projection to a child-only recursive column" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w247-offline-projection-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        StaticBinaryBulkTableW247Fixture.write_part(part, profile_name)
        child = File.join(part, "by_shape.proj")
        StaticBinaryBulkTableW247Fixture.write_projection_part(child, profile_name)

        table = w247_offline_table(
          part,
          projections: [CrystalClick::OfflineProjection.new("by_shape", "SELECT root_variant AS projected")],
        )
        observed = [] of CrystalClick::BinaryValue
        table.scan_projection_typed("by_shape", ["projected"], batch_rows: 2) do |batch|
          batch.column_type_for("projected").should eq(StaticBinaryBulkTableW247Fixture.variant_type.name)
          batch.part_name.should eq("all_1_1_0")
          observed.concat(batch.binary_bulk_values_for("projected").to_a)
        end
        w247_expect_rows!(observed, StaticBinaryBulkTableW247Fixture.rows_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN))

        late = [] of CrystalClick::BinaryValue
        table.scan_projection_typed_window("by_shape", ["projected"], 4_u64, 1) do |batch|
          batch.mark_index.should eq(2)
          batch.source_row_offset.should eq(4_u64)
          late.concat(batch.binary_bulk_values_for("projected").to_a)
        end
        w247_expect_rows!(late, StaticBinaryBulkTableW247Fixture.rows_for(StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN)[4, 1])
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "preserves static reader transport limits and rejects a truncated recursive stream" do
    parent = File.tempname("crystal-click-w247-static-adversary-")
    Dir.mkdir(parent)
    begin
      limited_part = File.join(parent, "limited")
      StaticBinaryBulkTableW247Fixture.write_part(limited_part, "single")
      tiny_transport = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 1)
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::BinaryBulkColumnReader.open(
          limited_part,
          StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN,
          StaticBinaryBulkTableW247Fixture.variant_type,
          transport_limits: tiny_transport,
        )
        reader.read_marks(0, 1)
      end

      corrupt_part = File.join(parent, "corrupt")
      StaticBinaryBulkTableW247Fixture.write_part(corrupt_part, "single")
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        StaticBinaryBulkTableW247Fixture.variant_type,
        StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN,
        StaticBinaryBulkTableW247Fixture.profile("single"),
      )
      role = physical.stream_names.keys.sort.find do |candidate|
        File.size(File.join(corrupt_part, physical.data_file_for(candidate, true))) > 1
      end.not_nil!
      data_path = File.join(corrupt_part, physical.data_file_for(role, true))
      bytes = File.read(data_path).to_slice
      File.write(data_path, bytes[0, bytes.size - 1])
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::BinaryBulkColumnReader.open(
          corrupt_part,
          StaticBinaryBulkTableW247Fixture::VARIANT_COLUMN,
          StaticBinaryBulkTableW247Fixture.variant_type,
        )
        reader.read_marks(0, 3)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
