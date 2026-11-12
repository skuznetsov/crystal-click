require "./spec_helper"
require "./support/projection_checksum_fixture"
require "file_utils"
require "digest/sha256"
require "../scripts/support/static_nested_handoff_w248_fixture"

private def w248_candidate(path : String, row_count : UInt64 = 5_u64) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, row_count)
end

private def w248_offline_table(
  path : String,
  row_count : UInt64 = 5_u64,
  projections : Array(CrystalClick::OfflineProjection) = [] of CrystalClick::OfflineProjection,
) : CrystalClick::OfflineTable
  columns = [CrystalClick::OfflineColumn.new("pk", "UInt64")] of CrystalClick::OfflineColumn
  StaticNestedHandoffW248Fixture.types.each do |name, type|
    columns << CrystalClick::OfflineColumn.new(name, type.name)
  end
  CrystalClick::OfflineTable.new(
    "events",
    "w248-static-nested",
    "MergeTree",
    columns,
    [w248_candidate(path, row_count)] of CrystalClick::OfflinePartCandidate,
    projections: projections,
  )
end

private def w248_expect_rows!(
  actual : Array(CrystalClick::BinaryValue),
  expected : Array(CrystalClick::BinaryValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    value.type.should eq(expected[index].type)
    value.type.name.should eq(expected[index].type.name)
    StaticNestedHandoffW248Fixture.row_signature(value).should eq(
      StaticNestedHandoffW248Fixture.row_signature(expected[index])
    )
  end
end

private def w248_no_stage(parent : String) : Nil
  Dir.children(parent).any?(&.starts_with?(".crystal-click-wide-writer-")).should be_false
end

private def w248_part_snapshot(path : String) : Hash(String, String)
  Dir.children(path).sort!.each_with_object({} of String => String) do |name, snapshot|
    file = File.join(path, name)
    snapshot[name] = Digest::SHA256.hexdigest(File.read(file)) if File.file?(file)
  end
end

describe "W248 recursive static nominal Nested handoff" do
  # Keep this first: on the pre-fix tree the direct generic Nested owner is the
  # positive control and the following N-column call exposes the actual input
  # admission refusal, before any consumer assertions can fail instead.
  it "admits direct and schema-wide static Nested with exact nominal rows" do
    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w248-static-nested-main-")
      Dir.mkdir(parent)
      begin
        direct_part = File.join(parent, "direct_1_1_0")
        StaticNestedHandoffW248Fixture.write_direct_control(direct_part, profile_name).should eq(direct_part)
        direct = CrystalClick::NestedBulkColumnReader.open(
          direct_part,
          StaticNestedHandoffW248Fixture::ROOT_COLUMN,
          StaticNestedHandoffW248Fixture.root_nested_type,
        )
        direct.schema_declaration.should eq(StaticNestedHandoffW248Fixture.root_nested_type.name)
        direct.source_declaration.should eq(StaticNestedHandoffW248Fixture.root_nested_type.name)
        direct.ordinary_profile.should eq(StaticNestedHandoffW248Fixture.profile(profile_name))
        direct.row_count.should eq(5_u64)
        direct.mark_row_counts.should eq(StaticNestedHandoffW248Fixture::MARK_ROW_COUNTS)
        direct_rows = direct.read_marks(0, direct.mark_count).flat_map { |mark| mark }
        w248_expect_rows!(
          direct_rows,
          StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::ROOT_COLUMN),
        )
        direct.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))

        part = File.join(parent, "all_1_1_0")
        StaticNestedHandoffW248Fixture.write_part(part, profile_name).should eq(part)

        types = StaticNestedHandoffW248Fixture.types
        columns_text = File.read(File.join(part, "columns.txt"))
        (StaticNestedHandoffW248Fixture::TARGET_COLUMNS + StaticNestedHandoffW248Fixture::STRING_COLUMNS).each do |name|
          columns_text.should contain("`#{name}` #{types[name].name}")
        end

        all_stream_names = Hash(String, Bool).new
        (StaticNestedHandoffW248Fixture::TARGET_COLUMNS + StaticNestedHandoffW248Fixture::STRING_COLUMNS).each do |name|
          physical = CrystalClick::BinaryBulkPhysicalPlan.new(
            types[name], name, StaticNestedHandoffW248Fixture.profile(profile_name)
          )
          physical.stream_names.each do |role, stream_name|
            all_stream_names.has_key?(stream_name).should be_false
            all_stream_names[stream_name] = true
            File.exists?(File.join(part, physical.data_file_for(role, true))).should be_true
            File.exists?(File.join(part, physical.marks_file_for(role, true))).should be_true
          end

          reader = CrystalClick::BinaryBulkColumnReader.open(part, name, types[name])
          reader.ordinary_profile.should eq(StaticNestedHandoffW248Fixture.profile(profile_name))
          reader.schema_declaration.should eq(types[name].name)
          reader.source_declaration.should eq(types[name].name)
          reader.row_count.should eq(5_u64)
          reader.mark_row_counts.should eq(StaticNestedHandoffW248Fixture::MARK_ROW_COUNTS)
          rows = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
          w248_expect_rows!(rows, StaticNestedHandoffW248Fixture.rows_for(name))
          w248_expect_rows!(
            reader.read_marks(2, 1).flat_map { |mark| mark },
            StaticNestedHandoffW248Fixture.rows_for(name)[4, 1],
          )
          reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))
        end

        selected = [StaticNestedHandoffW248Fixture::KEY_NAME] +
                   StaticNestedHandoffW248Fixture::TARGET_COLUMNS +
                   StaticNestedHandoffW248Fixture::STRING_COLUMNS
        table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
        table.column_types.should eq(
          [{StaticNestedHandoffW248Fixture::KEY_NAME, "UInt64"}] +
          StaticNestedHandoffW248Fixture::TARGET_COLUMNS.map { |name| {name, types[name].name} } +
          StaticNestedHandoffW248Fixture::STRING_COLUMNS.map { |name| {name, "String"} }
        )
        table.part_mark_row_counts.should eq([StaticNestedHandoffW248Fixture::MARK_ROW_COUNTS])
        table.total_row_count.should eq(5_u64)
        StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
          CrystalClick::StaticBinaryBulkColumnDeclaration.parse(types[name].name).should eq(types[name])
        end

        keys = [] of UInt64
        strings0 = [] of String
        strings1 = [] of String
        observed = Hash(String, Array(CrystalClick::BinaryValue)).new do |values, name|
          values[name] = [] of CrystalClick::BinaryValue
        end
        callback_marks = [] of Int32
        table.scan_typed do |batch|
          callback_marks << batch.mark_index
          keys.concat(batch.values_for(StaticNestedHandoffW248Fixture::KEY_NAME))
          strings0.concat(batch.strings_for(StaticNestedHandoffW248Fixture::STRING0_COLUMN))
          strings1.concat(batch.strings_for(StaticNestedHandoffW248Fixture::STRING1_COLUMN))
          StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
            batch.binary_bulk_values_for(name).each { |value| observed[name] << value }
          end
        end
        callback_marks.should eq([0, 1, 2])
        keys.should eq(StaticNestedHandoffW248Fixture::KEYS)
        strings0.should eq(StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::STRING0_COLUMN).map(&.as_string))
        strings1.should eq(StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::STRING1_COLUMN).map(&.as_string))
        StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
          w248_expect_rows!(observed[name], StaticNestedHandoffW248Fixture.rows_for(name))
        end

        # The table's established typed String reader remains a distinct route.
        [StaticNestedHandoffW248Fixture::STRING0_COLUMN, StaticNestedHandoffW248Fixture::STRING1_COLUMN].each do |name|
          reader = CrystalClick::WidePart.open_typed(part, name)
          expected = StaticNestedHandoffW248Fixture.rows_for(name).map(&.as_string)
          reader.read_string_mark_range(name, 0, reader.mark_count).should eq(expected)
        end

        [3_u64, 4_u64].each do |start_row|
          window_values = Hash(String, Array(CrystalClick::BinaryValue)).new do |values, name|
            values[name] = [] of CrystalClick::BinaryValue
          end
          window_keys = [] of UInt64
          table.scan_typed_window(start_row, 1) do |batch|
            window_keys.concat(batch.values_for(StaticNestedHandoffW248Fixture::KEY_NAME))
            StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
              batch.binary_bulk_values_for(name).each { |value| window_values[name] << value }
            end
          end
          expected_index = start_row.to_i
          window_keys.should eq(StaticNestedHandoffW248Fixture::KEYS[expected_index, 1])
          StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
            w248_expect_rows!(
              window_values[name],
              StaticNestedHandoffW248Fixture.rows_for(name)[expected_index, 1],
            )
          end
        end

        eof_callbacks = 0
        table.scan_typed_window(5_u64, 1) { |_batch| eof_callbacks += 1 }
        eof_callbacks.should eq(0)
        expect_raises(CrystalClick::BoundsError) do
          table.scan_typed_window(6_u64, 1) { |_batch| }
        end

        candidate_values = Hash(String, Array(CrystalClick::BinaryValue)).new do |values, name|
          values[name] = [] of CrystalClick::BinaryValue
        end
        candidate_marks = [] of Int32
        candidate_keys = [] of UInt64
        table.scan_typed_candidate_marks([[2_i32]]) do |batch|
          candidate_marks << batch.mark_index
          candidate_keys.concat(batch.values_for(StaticNestedHandoffW248Fixture::KEY_NAME))
          StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
            batch.binary_bulk_values_for(name).each { |value| candidate_values[name] << value }
          end
        end
        candidate_marks.should eq([2])
        candidate_keys.should eq([5_u64])
        StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
          w248_expect_rows!(candidate_values[name], StaticNestedHandoffW248Fixture.rows_for(name)[4, 1])
        end
        empty_candidate_callbacks = 0
        table.scan_typed_candidate_marks([[] of Int32]) { |_batch| empty_candidate_callbacks += 1 }
        empty_candidate_callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "keeps generic admission nominal and preserves illegal or contextual child guards" do
    types = StaticNestedHandoffW248Fixture.types
    StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
      CrystalClick::StaticBinaryBulkColumnDeclaration.new(types[name]).declaration.should eq(types[name].name)
    end

    unnamed_tuple_with_nested = CrystalClick::BinaryDataType.tuple(
      [StaticNestedHandoffW248Fixture.root_nested_type, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
    )
    unnamed_tuple_with_nested.name.should contain("Tuple(Nested(")
    CrystalClick::StaticBinaryBulkColumnDeclaration.new(unnamed_tuple_with_nested).declaration.should eq(
      unnamed_tuple_with_nested.name
    )

    variant_with_nested = CrystalClick::BinaryDataType.variant(
      [StaticNestedHandoffW248Fixture.root_nested_type, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
    )
    CrystalClick::StaticBinaryBulkColumnDeclaration.new(variant_with_nested).declaration.should eq(
      variant_with_nested.name
    )

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(StaticNestedHandoffW248Fixture.root_nested_type)
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    dynamic_nested = CrystalClick::BinaryDataType.nested(
      [dynamic, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      ["value", "note"] of String,
    )
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    json_nested = CrystalClick::BinaryDataType.nested(
      [json, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      ["value", "note"] of String,
    )
    [dynamic_nested, json_nested].each do |contextual_nested|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::StaticBinaryBulkColumnDeclaration.new(contextual_nested)
      end
    end
  end

  it "preserves exact offline Nested values and dispatches the declared projection child" do
    parent = File.tempname("crystal-click-w248-static-nested-offline-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      StaticNestedHandoffW248Fixture.write_part(part, "single")
      offline = w248_offline_table(part)
      StaticNestedHandoffW248Fixture::TARGET_COLUMNS.each do |name|
        values = offline[name].values(max_rows: 5_u64).map(&.as(CrystalClick::BinaryValue))
        w248_expect_rows!(values, StaticNestedHandoffW248Fixture.rows_for(name))
      end
      [StaticNestedHandoffW248Fixture::STRING0_COLUMN, StaticNestedHandoffW248Fixture::STRING1_COLUMN].each do |name|
        values = offline[name].values(max_rows: 5_u64).map(&.as(String))
        expected = StaticNestedHandoffW248Fixture.rows_for(name).map(&.as_string)
        values.should eq(expected)
      end
      expect_raises(CrystalClick::BoundsError) do
        offline[StaticNestedHandoffW248Fixture::RECURSIVE_COLUMN].values(max_rows: 4_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        offline[StaticNestedHandoffW248Fixture::ROOT_COLUMN].values(max_string_bytes: 1_u64)
      end

      projection_name = "nested_projection"
      projection_part = File.join(part, "#{projection_name}.proj")
      StaticNestedHandoffW248Fixture.write_projection_part(projection_part, "single")
      ProjectionChecksumFixture.rebind!(part, projection_name)
      projected_offline = w248_offline_table(
        part,
        projections: [CrystalClick::OfflineProjection.new(
          projection_name,
          "SELECT recursive_nested AS projected",
        )] of CrystalClick::OfflineProjection,
      )
      projection_rows = [] of CrystalClick::BinaryValue
      projected_offline.scan_projection_typed(projection_name, ["projected"]) do |batch|
        batch.binary_bulk_values_for("projected").each { |value| projection_rows << value }
      end
      w248_expect_rows!(
        projection_rows,
        StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::RECURSIVE_COLUMN),
      )
      projection_final = [] of CrystalClick::BinaryValue
      projected_offline.scan_projection_typed_window(projection_name, ["projected"], 4_u64, 1) do |batch|
        batch.binary_bulk_values_for("projected").each { |value| projection_final << value }
      end
      w248_expect_rows!(
        projection_final,
        StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::RECURSIVE_COLUMN)[4, 1],
      )
      projection_eof_callbacks = 0
      projected_offline.scan_projection_typed_window(projection_name, ["projected"], 5_u64, 1) do |_batch|
        projection_eof_callbacks += 1
      end
      projection_eof_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces the aggregate retained Nested mark limit before exposing a table callback" do
    parent = File.tempname("crystal-click-w248-static-nested-table-budget-")
    Dir.mkdir(parent)
    begin
      nested_type = StaticNestedHandoffW248Fixture.root_nested_type
      declaration = nested_type.name
      CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(declaration).should be_true

      record_type = nested_type.child_at(0)
      label_type = record_type.child_at(0)
      nullable_string_type = label_type.child_at(0)
      choice_type = record_type.child_at(1)
      large_text = String.new(Bytes.new(17 * 1024 * 1024, 0x78_u8))
      label = CrystalClick::BinaryValue.low_cardinality(
        label_type,
        CrystalClick::BinaryValue.nullable(
          nullable_string_type,
          CrystalClick::BinaryValue.string(large_text),
        ),
      )
      record = CrystalClick::BinaryValue.tuple(
        record_type,
        [
          label,
          CrystalClick::BinaryValue.variant_null(choice_type),
          CrystalClick::BinaryValue.string(""),
        ] of CrystalClick::BinaryValue,
      )
      large_value = CrystalClick::BinaryValue.nested(
        nested_type,
        [record, record] of CrystalClick::BinaryValue,
      )
      empty_value = CrystalClick::BinaryValue.nested(nested_type, [] of CrystalClick::BinaryValue)
      first = CrystalClick::WidePartColumn.binary_bulk(
        "large_a",
        nested_type,
        [[large_value, empty_value]] of Array(CrystalClick::BinaryValue),
      )
      second = CrystalClick::WidePartColumn.binary_bulk(
        "large_b",
        nested_type,
        [[large_value, empty_value]] of Array(CrystalClick::BinaryValue),
      )
      part = File.join(parent, "all_1_1_0")
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 4_096,
        max_elements: 1_000_000,
        max_bytes: 80 * 1024 * 1024,
      )
      transport_limits = CrystalClick::CompressedStreamLimits.new(
        max_decoded_bytes: 128 * 1024 * 1024,
        max_result_bytes: 128 * 1024 * 1024,
      )
      CrystalClick::WidePartWriter.write_uint64_columns(
        part,
        StaticNestedHandoffW248Fixture::KEY_NAME,
        Slice[1_u64, 2_u64],
        [first, second] of CrystalClick::WidePartColumn,
        rows_per_mark: 2,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        frame_bytes: 40 * 1024 * 1024,
        limits: limits,
        transport_limits: transport_limits,
      ).should eq(part)

      ["large_a", "large_b"].each do |name|
        single_callbacks = 0
        single_table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", name])
        single_table.scan_typed do |batch|
          single_callbacks += 1
          batch.values_for("pk").to_a.should eq([1_u64, 2_u64])
          values = batch.binary_bulk_values_for(name)
          values.size.should eq(2)
          values[0].type.should eq(nested_type)
          values[0].element_count.should eq(2)
          values[0].element_at(0).element_at(0).element_at(0).element_at(0).as_string.should eq(large_text)
          values[0].element_at(1).element_at(0).element_at(0).element_at(0).as_string.should eq(large_text)
          values[0].element_at(0).element_at(1).is_null?.should be_true
          values[0].element_at(1).element_at(1).is_null?.should be_true
          values[1].type.should eq(nested_type)
          values[1].element_count.should eq(0)
        end
        single_callbacks.should eq(1)
      end

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "large_a", "large_b"]).scan_typed do |_batch|
          callbacks += 1
        end
      end
      error.message.not_nil!.should eq("selected static BinaryBulk mark exceeds aggregate materialization limit")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-shape nominal substitution, ragged common grids and cumulative write overflow" do
    parent = File.tempname("crystal-click-w248-static-nested-guards-")
    Dir.mkdir(parent)
    begin
      substitution_part = File.join(parent, "shape_1_1_0")
      StaticNestedHandoffW248Fixture.write_array_tuple_substitution_part(substitution_part, "single")
      nested_type = StaticNestedHandoffW248Fixture.root_nested_type
      tuple_array_type = StaticNestedHandoffW248Fixture.array_tuple_substitution_type
      tuple_array_type.tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
      tuple_array_type.name.should_not eq(nested_type.name)
      tuple_array_type.child_at(0).should eq(nested_type.child_at(0))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkColumnReader.open(substitution_part, "shape_substitute", nested_type)
      end

      bad_grid_part = File.join(parent, "bad-grid_1_1_0")
      short_rows = StaticNestedHandoffW248Fixture.rows_for(StaticNestedHandoffW248Fixture::STRING0_COLUMN)[0, 4]
      malformed_column = CrystalClick::WidePartColumn.binary_bulk(
        StaticNestedHandoffW248Fixture::STRING0_COLUMN,
        CrystalClick::BinaryDataType.primitive("String"),
        StaticNestedHandoffW248Fixture.marks(short_rows),
      )
      grid_error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          bad_grid_part,
          StaticNestedHandoffW248Fixture::KEY_NAME,
          StaticNestedHandoffW248Fixture::KEYS.to_unsafe.to_slice(StaticNestedHandoffW248Fixture::KEYS.size),
          [malformed_column] of CrystalClick::WidePartColumn,
          rows_per_mark: StaticNestedHandoffW248Fixture::ROWS_PER_MARK,
          profile: StaticNestedHandoffW248Fixture.profile("single"),
          shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        )
      end
      grid_error.message.not_nil!.should eq("parent granule count does not match the key mark grid")
      Dir.exists?(bad_grid_part).should be_false
      w248_no_stage(parent)

      one_column_part = File.join(parent, "one-u64_1_1_0")
      two_column_part = File.join(parent, "two-u64_1_1_0")
      u64 = CrystalClick::BinaryDataType.primitive("UInt64")
      first_values = [
        [1_u64, 2_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
        [3_u64, 4_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
        [5_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      ]
      second_values = [
        [11_u64, 12_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
        [13_u64, 14_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
        [15_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      ]
      one = CrystalClick::WidePartColumn.binary_bulk(
        "one", u64, first_values
      )
      two = CrystalClick::WidePartColumn.binary_bulk(
        "two", u64, second_values
      )
      transport_limit = CrystalClick::CompressedStreamLimits.new(
        max_decoded_bytes: 120,
      )
      writer_args = {
        rows_per_mark:    2,
        profile:          CrystalClick::BinaryBulkProfile.single_stream,
        shared_profile:   CrystalClick::BinaryBulkProfile.single_stream,
        transport_limits: transport_limit,
      }
      CrystalClick::WidePartWriter.write_uint64_columns(
        one_column_part,
        StaticNestedHandoffW248Fixture::KEY_NAME,
        StaticNestedHandoffW248Fixture::KEYS.to_unsafe.to_slice(StaticNestedHandoffW248Fixture::KEYS.size),
        [one] of CrystalClick::WidePartColumn,
        rows_per_mark: writer_args[:rows_per_mark],
        profile: writer_args[:profile],
        shared_profile: writer_args[:shared_profile],
        transport_limits: writer_args[:transport_limits],
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          two_column_part,
          StaticNestedHandoffW248Fixture::KEY_NAME,
          StaticNestedHandoffW248Fixture::KEYS.to_unsafe.to_slice(StaticNestedHandoffW248Fixture::KEYS.size),
          [one, two] of CrystalClick::WidePartColumn,
          rows_per_mark: writer_args[:rows_per_mark],
          profile: writer_args[:profile],
          shared_profile: writer_args[:shared_profile],
          transport_limits: writer_args[:transport_limits],
        )
      end
      Dir.exists?(two_column_part).should be_false
      w248_no_stage(parent)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps overwrite publication exclusive and checks recursive Nested grids and payloads" do
    parent = File.tempname("crystal-click-w248-static-nested-publication-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      StaticNestedHandoffW248Fixture.write_part(part, "single")
      before = w248_part_snapshot(part)
      overwrite_error = expect_raises(ArgumentError) do
        StaticNestedHandoffW248Fixture.write_part(part, "single")
      end
      overwrite_error.message.not_nil!.should eq("destination must not already exist")
      w248_part_snapshot(part).should eq(before)
      w248_no_stage(parent)

      recursive_type = StaticNestedHandoffW248Fixture.recursive_nested_type
      recursive_column = StaticNestedHandoffW248Fixture::RECURSIVE_COLUMN
      expected_grid = StaticNestedHandoffW248Fixture::MARK_ROW_COUNTS + [0_u64]
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(
        recursive_type,
        recursive_column,
        StaticNestedHandoffW248Fixture.profile("single"),
      )
      role = physical.stream_names.keys.sort.find do |candidate|
        marks_path = File.join(part, physical.marks_file_for(candidate, true))
        File.exists?(marks_path) && File.size(marks_path) == (expected_grid.size * 24).to_i64
      end.not_nil!
      marks_path = File.join(part, physical.marks_file_for(role, true))
      mark_bytes = File.read(marks_path).to_slice.dup
      mark_bytes.size.should eq(expected_grid.size * 24)
      expected_grid.each_with_index do |expected_rows, index|
        row_count_offset = index * 24 + 16
        actual_rows = 0_u64
        8.times do |byte|
          actual_rows |= mark_bytes[row_count_offset + byte].to_u64 << (byte * 8)
        end
        actual_rows.should eq(expected_rows)
      end
      # Preserve the file size and mark offsets while invalidating one common
      # parent-row count. Empty candidate selection must still preflight grids.
      mark_bytes[1 * 24 + 16] = 9_u8
      File.write(marks_path, mark_bytes)
      table_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed(
          [part],
          [StaticNestedHandoffW248Fixture::KEY_NAME, recursive_column],
        )
        table.scan_typed_candidate_marks([[] of Int32]) { |_batch| table_callbacks += 1 }
      end
      table_callbacks.should eq(0)

      # Restore a clean generated part, then truncate one selected physical
      # stream to distinguish payload/roster binding from row-grid preflight.
      FileUtils.rm_rf(part)
      StaticNestedHandoffW248Fixture.write_part(part, "single")
      data_role = physical.stream_names.keys.sort.first
      data_path = File.join(part, physical.data_file_for(data_role, true))
      data_bytes = File.read(data_path).to_slice.dup
      data_bytes.should_not be_empty
      File.write(data_path, data_bytes[0, data_bytes.size - 1])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkColumnReader.open(part, recursive_column, recursive_type)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
