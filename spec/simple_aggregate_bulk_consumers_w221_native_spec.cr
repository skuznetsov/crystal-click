require "./spec_helper"
require "file_utils"

private def w221_offline_nullable_uint64_aggregate_type : CrystalClick::BinaryDataType
  function = CrystalClick::BinarySimpleAggregateType::Function::AnyLastRespectNulls
  storage = CrystalClick::BinaryDataType.nullable(
    CrystalClick::BinaryDataType.primitive("UInt64")
  )
  CrystalClick::BinaryDataType.simple_aggregate(function, storage)
end

private def w221_offline_aggregate_type(source : String) : CrystalClick::BinaryDataType
  CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source) ||
    raise "W221 consumer fixture declaration was not admitted: #{source}"
end

private def w221_offline_profile_part_path(fixture_root : String, profile_id : String) : String
  File.join(fixture_root, "parts", profile_id, "all_1_1_0")
end

private def w221_offline_profile_table(
  type_name : String,
  candidates : Array(CrystalClick::OfflinePartCandidate),
) : CrystalClick::OfflineTable
  CrystalClick::OfflineTable.new(
    "w221_events",
    "w221-offline-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("k", "UInt64"),
      CrystalClick::OfflineColumn.new("v", type_name),
    ] of CrystalClick::OfflineColumn,
    candidates
  )
end

private def w221_offline_single_profile_table(
  type_name : String,
  fixture_root : String,
  profile_id : String,
) : CrystalClick::OfflineTable
  part_path = w221_offline_profile_part_path(fixture_root, profile_id)
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part_path, info, 5_u64)
  w221_offline_profile_table(type_name, [candidate] of CrystalClick::OfflinePartCandidate)
end

private def w221_offline_values(
  table : CrystalClick::OfflineTable,
  max_rows : UInt64 = 5_u64,
  max_string_bytes : UInt64 = CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
) : Array(CrystalClick::BinaryValue)
  table["v"].values(max_rows: max_rows, max_string_bytes: max_string_bytes).map do |value|
    value.as(CrystalClick::BinaryValue)
  end
end

private def w221_assert_inner_nullable_values(
  values : Array(CrystalClick::BinaryValue),
  type : CrystalClick::BinaryDataType,
  expected_rows : Int,
) : Nil
  values.size.should eq(expected_rows)
  values.each_with_index do |value, index|
    value.type.should eq(type)
    value.is_null?.should be_false
    # BinaryValue#as_simple_aggregate returns the SAF storage child itself;
    # here that child is the nominal Nullable value.
    nullable_child = value.as_simple_aggregate
    nullable_child.type.should eq(type.child_at(0))
    nullable_child.is_null?.should eq(index == 1)
    unless nullable_child.is_null?
      leaf = nullable_child.child_at(0)
      leaf.type.should eq(type.child_at(0).child_at(0))
    end
  end

  # The row after inner NULL is a present zero/default, not a missing SAF root.
  zero_leaf = values[2].as_simple_aggregate.child_at(0)
  zero_leaf.bytes.all? { |byte| byte == 0_u8 }.should be_true
  nil
end

private def w221_synthetic_candidate(
  part_name : String,
  part_path : String,
) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse(part_name).not_nil!
  CrystalClick::OfflinePartCandidate.new(part_name, part_path, info, 5_u64)
end

# This native/integration check is opt-in because it reads immutable parts
# copied from an independent ClickHouse-authored fixture matrix.
if fixture_root = ENV["W221_PART_ROOT"]?
  describe "W221 SimpleAggregateFunction public bulk consumers" do
    it "materializes UInt64 inner NULL, zero, and adjacent non-NULL rows with exact identity" do
      source = "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(UInt64))"
      type = w221_offline_nullable_uint64_aggregate_type
      type.name.should eq(source)

      # The older typed facade remains scalar-child-only. The generic public
      # BinaryValue route must not widen that API or flatten the SAF wrapper.
      CrystalClick::WidePart.supports_typed_type?(type.name).should be_false
      CrystalClick::SimpleAggregateColumnType.parse(type.name).should be_nil
      CrystalClick::WidePart.supports_simple_aggregate_bulk_type?(type.name).should be_true

      table = w221_offline_single_profile_table(source, fixture_root, "anyLast_respect_nulls_uint64_inner_nullable")
      values = w221_offline_values(table)
      w221_assert_inner_nullable_values(values, type, 5)

      values[0].as_simple_aggregate.child_at(0).as_uint64.should eq(UInt64::MAX)
      values[1].as_simple_aggregate.is_null?.should be_true
      values[2].as_simple_aggregate.child_at(0).as_uint64.should eq(0_u64)
      values[3].as_simple_aggregate.child_at(0).as_uint64.should eq(0x7fff_ffff_ffff_ffff_u64)
      values[4].as_simple_aggregate.child_at(0).as_uint64.should eq(0xffff_ffff_ffff_ffee_u64)
    end

    it "preserves nominal inner Nullable values across String, signed, Decimal, and temporal profiles" do
      profiles = [
        {
          "anyLast_respect_nulls_string_inner_nullable_single_stream",
          "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))",
        },
        {
          "anyLast_respect_nulls_string_inner_nullable_with_size_stream",
          "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))",
        },
        {
          "anyLast_respect_nulls_int32_inner_nullable",
          "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(Int32))",
        },
        {
          "anyLast_respect_nulls_decimal_p38_s5_inner_nullable",
          "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(Decimal(38, 5)))",
        },
        {
          "anyLast_respect_nulls_datetime64_s3_utc_inner_nullable",
          "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(DateTime64(3, 'UTC')))",
        },
      ]

      profiles.each do |profile_id, source|
        type = w221_offline_aggregate_type(source)
        table = w221_offline_single_profile_table(source, fixture_root, profile_id)
        values = w221_offline_values(table)
        w221_assert_inner_nullable_values(values, type, 5)

        leaf = values[0].as_simple_aggregate.child_at(0)
        leaf_type = type.child_at(0).child_at(0)
        if leaf_type.tag == CrystalClick::BinaryDataType::TAG_STRING
          leaf.as_string.to_slice.should eq(Bytes[0x65_u8, 0x64_u8, 0x67_u8, 0x65_u8, 0x00_u8, 0xff_u8])
          values[3].as_simple_aggregate.child_at(0).as_string.to_slice.should eq(
            Bytes[0x00_u8, 0x7f_u8, 0x00_u8]
          )
          values[4].as_simple_aggregate.child_at(0).as_string.to_slice.should eq(
            Bytes[0x74_u8, 0x61_u8, 0x69_u8, 0x6c_u8, 0x00_u8]
          )
        else
          # Check measured leaf payloads directly, including a non-default
          # adjacent row, rather than relying only on width and zero behavior.
          if leaf_type.tag == CrystalClick::BinaryDataType::TAG_INT32
            leaf.bytes.should eq(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0x7f_u8])
            values[3].as_simple_aggregate.child_at(0).bytes.should eq(
              Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
            )
          elsif leaf_type.tag == CrystalClick::BinaryDataType::TAG_DECIMAL32 ||
                leaf_type.tag == CrystalClick::BinaryDataType::TAG_DECIMAL64 ||
                leaf_type.tag == CrystalClick::BinaryDataType::TAG_DECIMAL128 ||
                leaf_type.tag == CrystalClick::BinaryDataType::TAG_DECIMAL256
            leaf.bytes.should eq(
              Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x3f_u8, 0x22_u8, 0x8a_u8, 0x09_u8,
                0x7a_u8, 0xc4_u8, 0x86_u8, 0x5a_u8, 0xa8_u8, 0x4c_u8, 0x3b_u8, 0x4b_u8]
            )
            values[3].as_simple_aggregate.child_at(0).bytes.should eq(
              Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xc0_u8, 0xdd_u8, 0x75_u8, 0xf6_u8,
                0x85_u8, 0x3b_u8, 0x79_u8, 0xa5_u8, 0x57_u8, 0xb3_u8, 0xc4_u8, 0xb4_u8]
            )
          elsif leaf_type.tag == CrystalClick::BinaryDataType::TAG_DATETIME64 ||
                leaf_type.tag == CrystalClick::BinaryDataType::TAG_DATETIME64_ZONE
            leaf.bytes.should eq(Bytes[0xff_u8, 0x1b_u8, 0x39_u8, 0xa1_u8, 0x78_u8, 0x09_u8, 0x00_u8, 0x00_u8])
            values[3].as_simple_aggregate.child_at(0).bytes.should eq(
              Bytes[0x00_u8, 0x38_u8, 0x28_u8, 0xb3_u8, 0xfd_u8, 0xfd_u8, 0xff_u8, 0xff_u8]
            )
          end
          values[2].as_simple_aggregate.child_at(0).bytes.all? { |byte| byte == 0_u8 }.should be_true
          leaf.byte_size.should eq(type.child_at(0).child_at(0).fixed_width.not_nil!)
        end
      end
    end

    it "exposes borrowed typed batches through one generic BinaryValue accessor" do
      profile_id = "anyLast_respect_nulls_string_inner_nullable_with_size_stream"
      source = "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))"
      type = w221_offline_aggregate_type(source)
      part_path = w221_offline_profile_part_path(fixture_root, profile_id)
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["v"])
      table.column_types.should eq([{"v", source}])

      values = [] of CrystalClick::BinaryValue
      table.scan_typed(batch_rows: 2) do |batch|
        batch.column_type_for("v").should eq(source)
        values.concat(batch.binary_bulk_values_for("v").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.dynamic_bulk_values_for("v")
        end
      end
      w221_assert_inner_nullable_values(values, type, 5)
      values[0].as_simple_aggregate.child_at(0).as_string.to_slice.should eq(
        Bytes[0x65_u8, 0x64_u8, 0x67_u8, 0x65_u8, 0x00_u8, 0xff_u8]
      )
    end

    it "enforces String payload budgets cumulatively across marks and synthetic disjoint parts" do
      profile_id = "anyLast_respect_nulls_string_inner_nullable_single_stream"
      source = "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))"
      type = w221_offline_aggregate_type(source)
      single = w221_offline_single_profile_table(source, fixture_root, profile_id)

      # The largest individual String is six bytes, but the five rows retain
      # fourteen payload bytes across the independent physical marks.
      expect_raises(CrystalClick::BoundsError) do
        w221_offline_values(single, max_string_bytes: 10_u64)
      end

      # Synthetic candidate set only: the same immutable fixture bytes are
      # copied under two disjoint logical part identities. This checks that
      # the owned-values budget accumulates across candidates; it does not
      # claim that the fixture matrix contains a native multi-part table.
      parent = File.tempname("crystal-click-w221-synthetic-multipart-")
      Dir.mkdir(parent)
      begin
        source_path = w221_offline_profile_part_path(fixture_root, profile_id)
        first_path = File.join(parent, "all_1_1_0")
        second_path = File.join(parent, "all_2_2_0")
        FileUtils.cp_r(source_path, first_path)
        FileUtils.cp_r(source_path, second_path)
        candidates = [
          w221_synthetic_candidate("all_1_1_0", first_path),
          w221_synthetic_candidate("all_2_2_0", second_path),
        ] of CrystalClick::OfflinePartCandidate
        synthetic = w221_offline_profile_table(source, candidates)

        expect_raises(CrystalClick::BoundsError) do
          w221_offline_values(synthetic, max_rows: 10_u64, max_string_bytes: 20_u64)
        end

        values = w221_offline_values(synthetic, max_rows: 10_u64, max_string_bytes: 30_u64)
        w221_assert_inner_nullable_values(values[0, 5], type, 5)
        w221_assert_inner_nullable_values(values[5, 5], type, 5)
      ensure
        FileUtils.rm_rf(parent)
      end
    end

    it "rejects wrong source identity and wrong Nullable placement without widening legacy guards" do
      inner_string = "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))"
      wrong_function = "SimpleAggregateFunction(any_respect_nulls, Nullable(String))"
      outer_nullable = "Nullable(SimpleAggregateFunction(anyLast_respect_nulls, String))"
      bare_storage = "SimpleAggregateFunction(anyLast_respect_nulls, String)"

      CrystalClick::WidePart.supports_simple_aggregate_bulk_type?(wrong_function).should be_true
      CrystalClick::WidePart.supports_simple_aggregate_bulk_type?(outer_nullable).should be_false
      CrystalClick::WidePart.supports_simple_aggregate_bulk_type?(bare_storage).should be_false
      CrystalClick::WidePart.supports_typed_type?(inner_string).should be_false

      mismatched = w221_offline_single_profile_table(
        wrong_function,
        fixture_root,
        "anyLast_respect_nulls_string_inner_nullable_single_stream"
      )
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        mismatched["v"].values(max_rows: 5_u64)
      end

      too_few_rows = w221_offline_single_profile_table(
        inner_string,
        fixture_root,
        "anyLast_respect_nulls_string_inner_nullable_single_stream"
      )
      expect_raises(CrystalClick::BoundsError) do
        too_few_rows["v"].values(max_rows: 4_u64)
      end
    end

    it "binds typed SAF reads to a selected projection child, not the parent directory" do
      parent = File.tempname("crystal-click-w221-projection-child-")
      Dir.mkdir(parent)
      begin
        parent_path = File.join(parent, "all_1_1_0")
        FileUtils.cp_r(
          w221_offline_profile_part_path(fixture_root, "anyLast_respect_nulls_uint64_inner_nullable"),
          parent_path
        )
        child_path = File.join(parent_path, "selected.proj")
        FileUtils.cp_r(
          w221_offline_profile_part_path(fixture_root, "anyLast_respect_nulls_string_inner_nullable_single_stream"),
          child_path
        )

        source = "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(String))"
        type = w221_offline_aggregate_type(source)
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_path],
          "selected",
          ["v"]
        )
        table.column_types.should eq([{"v", source}])

        values = [] of CrystalClick::BinaryValue
        table.scan_typed(batch_rows: 2) do |batch|
          values.concat(batch.binary_bulk_values_for("v").to_a)
        end
        w221_assert_inner_nullable_values(values, type, 5)
        values[0].as_simple_aggregate.child_at(0).as_string.to_slice.should eq(
          Bytes[0x65_u8, 0x64_u8, 0x67_u8, 0x65_u8, 0x00_u8, 0xff_u8]
        )
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
