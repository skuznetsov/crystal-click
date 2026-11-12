require "./spec_helper"
require "./support/projection_checksum_fixture"
require "file_utils"
require "./support/simple_aggregate_w170_types"

# Test-only readback probes exercise writer validation at the private staged
# location. A mismatch in mark 1 must abort before the staged part is published.
class CrystalClick::WidePart
  class_property w170_scalar_readback_probe = false
  class_property w170_nullable_readback_probe = false

  def read_simple_aggregate_temporal_raw_mark_range(
    column : String,
    first_mark : Int,
    mark_count : Int,
    function : CrystalClick::BinarySimpleAggregateType::Function,
    storage_type_name : String,
    type : T.class,
  ) : Array(T) forall T
    observed = previous_def
    {% if T == Int32 %}
      if CrystalClick::WidePart.w170_scalar_readback_probe && first_mark == 1 && !observed.empty?
        observed[0] &+= 1_i32
      end
    {% end %}
    observed
  end

  def read_nullable_simple_aggregate_temporal_raw_mark_range(
    column : String,
    first_mark : Int,
    mark_count : Int,
    function : CrystalClick::BinarySimpleAggregateType::Function,
    storage_type_name : String,
    type : T.class,
  ) : Array(T?) forall T
    observed = previous_def
    {% if T == Int32 %}
      if CrystalClick::WidePart.w170_nullable_readback_probe && first_mark == 1
        index = observed.index { |value| !value.nil? }
        if index
          observed[index] = observed[index].not_nil! &+ 1_i32
        end
      end
    {% end %}
    observed
  end
end

private def w170_runtime_profiles : Array(W170TemporalProfile)
  leaves = [
    "date",
    "date32",
    "datetime_europe_berlin",
    "datetime64_s9_america_argentina_comodrivadavia",
    "time",
    "time64_s3",
  ]
  profiles = W170SimpleAggregateTemporalTestSupport.accepted_profiles.select do |profile|
    leaves.includes?(profile.leaf.key)
  end
  profiles.size.should eq(48)
  longest_nullable_names = profiles.select do |profile|
    profile.leaf.key == "datetime64_s9_america_argentina_comodrivadavia" && profile.nullable
  end.map(&.type_name.bytesize)
  longest_nullable_names.should contain(89)
  longest_nullable_names.should contain(93)
  longest_nullable_names.each do |bytesize|
    # These canonical Nullable SAF names exceed the historical W169 80-byte
    # bound, but remain within the current parser cap.
    bytesize.should be > 80
    bytesize.should be <= CrystalClick::SimpleAggregateColumnType::MAX_TYPE_BYTES
  end
  profiles
end

private def w170_runtime_values(profile : W170TemporalProfile, type : T.class) : Array(T) forall T
  W170SimpleAggregateTemporalTestSupport.library_values(profile, T)
end

private def w170_runtime_write_part(profile : W170TemporalProfile, values : Array(T), part : String) : Nil forall T
  FileUtils.mkdir_p(File.dirname(part))
  keys = W170_TEMPORAL_KEYS
  key_slice = keys.to_unsafe.to_slice(keys.size)
  if profile.nullable
    nullable_values = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_temporal_pair(
      part, "pk", key_slice, "v", nullable_values.to_unsafe.to_slice(nullable_values.size),
      profile.function, profile.storage_type_name, rows_per_mark: 2)
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_temporal_pair(
      part, "pk", key_slice, "v", values.to_unsafe.to_slice(values.size),
      profile.function, profile.storage_type_name, rows_per_mark: 2)
  end
  nil
end

private def w170_runtime_assert_scalar_batch(
  batch : CrystalClick::WidePartTableBatch,
  profile : W170TemporalProfile,
  expected : Array(T),
) : Nil forall T
  actual = batch.simple_aggregate_temporal_raw_values_for(
    "v", profile.function, profile.storage_type_name, T,
  ).to_a
  actual.should eq(expected)
end

private def w170_runtime_assert_nullable_batch(
  batch : CrystalClick::WidePartTableBatch,
  profile : W170TemporalProfile,
  expected : Array(T?),
) : Nil forall T
  actual = batch.nullable_simple_aggregate_temporal_raw_values_for(
    "v", profile.function, profile.storage_type_name, T,
  ).to_a
  actual.should eq(expected)
end

private def w170_runtime_create_catalog(
  root : String,
  part : String,
  type_name : String,
  id : Int32,
  projection_part : String? = nil,
) : Nil
  suffix = id.to_s.rjust(12, '0')
  database_uuid = "17000000-0000-4000-8000-#{suffix}"
  table_uuid = "17000000-0000-4000-8000-#{(id + 1).to_s.rjust(12, '0')}"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  projection = projection_part ? ",\n    PROJECTION `by_rollup` (SELECT pk, v ORDER BY pk)" : ""
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{type_name}#{projection}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  parent_part = File.join(table_path, "all_1_1_0")
  FileUtils.cp_r(part, parent_part)
  if projection_part
    FileUtils.cp_r(projection_part, File.join(parent_part, "by_rollup.proj"))
    ProjectionChecksumFixture.rebind!(parent_part, "by_rollup")
  end
  nil
end

private def w170_runtime_check_profile(profile : W170TemporalProfile, root : String, id : Int32) : Nil
  part = File.join(root, "part_#{profile.id}", "all_1_1_0")
  case profile.leaf.carrier_type_name
  when "UInt16"
    w170_runtime_check_profile_typed(profile, root, part, id, UInt16)
  when "Int32"
    w170_runtime_check_profile_typed(profile, root, part, id, Int32)
  when "UInt32"
    w170_runtime_check_profile_typed(profile, root, part, id, UInt32)
  when "Int64"
    w170_runtime_check_profile_typed(profile, root, part, id, Int64)
  else
    raise "unknown W170 temporal carrier"
  end
end

private def w170_runtime_check_profile_typed(
  profile : W170TemporalProfile,
  root : String,
  part : String,
  id : Int32,
  type : T.class,
) : Nil forall T
  values = w170_runtime_values(profile, T)
  w170_runtime_write_part(profile, values, part)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(profile.type_name)
  if profile.nullable
    expected = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
    reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.storage_type_name, T,
    ).should eq(expected)
    reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
      "v", 1, 1, profile.function, profile.storage_type_name, T,
    ).should eq(expected[2, 2])
    expect_raises(CrystalClick::BoundsError) do
      reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
        "v", reader.mark_count, 0, profile.function, profile.storage_type_name, T,
      )
    end
  else
    reader.read_simple_aggregate_temporal_raw_mark_range(
      "v", 0, reader.mark_count, profile.function, profile.storage_type_name, T,
    ).should eq(values)
    reader.read_simple_aggregate_temporal_raw_mark_range(
      "v", 1, 1, profile.function, profile.storage_type_name, T,
    ).should eq(values[2, 2])
    expect_raises(CrystalClick::BoundsError) do
      reader.read_simple_aggregate_temporal_raw_mark_range(
        "v", reader.mark_count, 0, profile.function, profile.storage_type_name, T,
      )
    end
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  window_rows = 0
  table.scan_typed_window(1_u64, 3) do |batch|
    keys = batch.values_for("pk", UInt64).to_a
    start = batch.part_row_offset.to_i
    keys.should eq(W170_TEMPORAL_KEYS[start, keys.size])
    if profile.nullable
      expected = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
      w170_runtime_assert_nullable_batch(batch, profile, expected[start, keys.size])
    else
      w170_runtime_assert_scalar_batch(batch, profile, values[start, keys.size])
    end
    window_rows += keys.size
  end
  window_rows.should eq(3)
  empty_callbacks = 0
  table.scan_typed_window(table.total_row_count, 3) { |_| empty_callbacks += 1 }
  empty_callbacks.should eq(0)

  catalog_root = File.join(root, "catalog_#{id}")
  w170_runtime_create_catalog(catalog_root, part, profile.type_name, id)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  if profile.nullable
    expected = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
    actual = offline["v"].values(max_rows: values.size.to_u64).map { |value| value.as(T?) }
    actual.should eq(expected)
  else
    actual = offline["v"].values(max_rows: values.size.to_u64).map { |value| value.as(T) }
    actual.should eq(values)
  end
  nil
end

private def w170_runtime_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = (value >> (index * 8)).to_u8
  end
  nil
end

private def w170_runtime_corrupt_second_value_mark(part : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "v")
  bytes = File.read(reader.mark_path).to_slice.dup
  offset = CrystalClick::WidePart::MARK_SIZE + 8
  previous_offset = 0_u64
  8.times do |index|
    previous_offset |= bytes[offset + index].to_u64 << (index * 8)
  end
  w170_runtime_write_u64(bytes, offset, previous_offset + 4_u64)
  File.write(reader.mark_path, bytes)
  nil
end

describe "W170 temporal SimpleAggregateFunction paired runtime paths" do
  it "round-trips each temporal family, admitted function, and outer shape through reader, table windows, and OfflineTable" do
    root = File.tempname("crystal-click-simple-aggregate-temporal-w170-runtime")
    begin
      profiles = w170_runtime_profiles
      profiles.each_with_index do |profile, index|
        w170_runtime_check_profile(profile, root, index.to_i32 * 2 + 1)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps function, family, scale, zone, carrier, shape, ordinary accessors, and inferred writers exact" do
    root = File.tempname("crystal-click-simple-aggregate-temporal-w170-guards")
    begin
      profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "DateTime64(9, '#{W170_TEMPORAL_LONGEST_ZONE}')" &&
          candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Max && !candidate.nullable
      end.not_nil!
      values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int64)
      part = File.join(root, "scaled", "all_1_1_0")
      w170_runtime_write_part(profile, values, part)
      reader = CrystalClick::WidePart.open_typed(part, "v")
      bad_mark = reader.mark_count + 1

      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, CrystalClick::BinarySimpleAggregateType::Function::Min,
          profile.storage_type_name, Int64,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, profile.function, "DateTime64(8, '#{W170_TEMPORAL_LONGEST_ZONE}')", Int64,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, profile.function, "Time64(9)", Int64,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, profile.function, "DateTime64(9, 'UTC')", Int64,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, profile.function, profile.storage_type_name, Int32,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
          "v", bad_mark, 1, profile.function, profile.storage_type_name, Int64,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_datetime64_ticks_mark_range("v", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("v", 0, 1, Int64)
      end

      inferred = File.join(root, "inferred", "all_1_1_0")
      inferred_values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int64)
      FileUtils.mkdir_p(File.dirname(inferred))
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        inferred, "pk", W170_TEMPORAL_KEYS.to_unsafe.to_slice(5),
        "v", inferred_values.to_unsafe.to_slice(5), rows_per_mark: 2)
      inferred_reader = CrystalClick::WidePart.open_typed(inferred, "v")
      inferred_reader.column_type.should eq("Int64")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        inferred_reader.read_simple_aggregate_temporal_raw_mark_range(
          "v", 0, 1, profile.function, profile.storage_type_name, Int64,
        )
      end

      budget_profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Any && !candidate.nullable
      end.not_nil!
      scalar32 = W170SimpleAggregateTemporalTestSupport.library_values(budget_profile, Int32)
      budget_parent = File.join(root, "budget")
      FileUtils.mkdir_p(budget_parent)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_temporal_pair(
          File.join(budget_parent, "scalar_1_1_0"), "pk", W170_TEMPORAL_KEYS.to_unsafe.to_slice(5),
          "v", scalar32.to_unsafe.to_slice(5), budget_profile.function, budget_profile.storage_type_name,
          rows_per_mark: CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1,
        )
      end
      nullable_values = W170SimpleAggregateTemporalTestSupport.nullable_values(scalar32)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_temporal_pair(
          File.join(budget_parent, "nullable_1_1_0"), "pk", W170_TEMPORAL_KEYS.to_unsafe.to_slice(5),
          "v", nullable_values.to_unsafe.to_slice(5), budget_profile.function, budget_profile.storage_type_name,
          rows_per_mark: CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1,
        )
      end
      Dir.children(budget_parent).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights each whole intersecting scalar and Nullable mark before callbacks" do
    root = File.tempname("crystal-click-simple-aggregate-temporal-w170-null-truncation")
    begin
      scalar_profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Any && !candidate.nullable
      end.not_nil!
      scalar_values = W170SimpleAggregateTemporalTestSupport.library_values(scalar_profile, Int32)
      scalar_part = File.join(root, "scalar", "all_1_1_0")
      w170_runtime_write_part(scalar_profile, scalar_values, scalar_part)
      w170_runtime_corrupt_second_value_mark(scalar_part)
      scalar_table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
      scalar_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        # Row 3 selects one row of mark 1; decoding/preflight still owns the
        # entire two-row mark before a callback can observe anything.
        scalar_table.scan_typed_window(3_u64, 1) { |_| scalar_callbacks += 1 }
      end
      scalar_callbacks.should eq(0)

      profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Any && candidate.nullable
      end.not_nil!
      values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int32)
      part = File.join(root, "nullable", "all_1_1_0")
      w170_runtime_write_part(profile, values, part)
      w170_runtime_corrupt_second_value_mark(part)
      reader = CrystalClick::WidePart.open_typed(part, "v")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_nullable_simple_aggregate_temporal_raw_mark_range(
          "v", 1, 1, profile.function, profile.storage_type_name, Int32,
        )
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[1_i32]]) { |_| callbacks += 1 }
      end
      callbacks.should eq(0)

      window_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        # Same whole-mark preflight applies beneath an outer Nullable shape.
        table.scan_typed_window(3_u64, 1) { |_| window_callbacks += 1 }
      end
      window_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "checks scalar and Nullable staged readback at mark 1 before publishing" do
    root = File.tempname("crystal-click-simple-aggregate-temporal-w170-stage-readback")
    begin
      parent = File.join(root, "parts")
      FileUtils.mkdir_p(parent)
      profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Any
      end.not_nil!
      values = W170SimpleAggregateTemporalTestSupport.library_values(profile, Int32)

      CrystalClick::WidePart.w170_scalar_readback_probe = true
      begin
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_temporal_pair(
            File.join(parent, "scalar_1_1_0"), "pk", W170_TEMPORAL_KEYS.to_unsafe.to_slice(5),
            "v", values.to_unsafe.to_slice(5), profile.function, profile.storage_type_name, rows_per_mark: 2)
        end
      ensure
        CrystalClick::WidePart.w170_scalar_readback_probe = false
      end
      Dir.children(parent).should be_empty

      nullable_profile = W170SimpleAggregateTemporalTestSupport.accepted_profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Any && candidate.nullable
      end.not_nil!
      nullable = W170SimpleAggregateTemporalTestSupport.nullable_values(values)
      CrystalClick::WidePart.w170_nullable_readback_probe = true
      begin
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_temporal_pair(
            File.join(parent, "nullable_1_1_0"), "pk", W170_TEMPORAL_KEYS.to_unsafe.to_slice(5),
            "v", nullable.to_unsafe.to_slice(5), nullable_profile.function,
            nullable_profile.storage_type_name, rows_per_mark: 2)
        end
      ensure
        CrystalClick::WidePart.w170_nullable_readback_probe = false
      end
      Dir.children(parent).should be_empty
    ensure
      CrystalClick::WidePart.w170_scalar_readback_probe = false
      CrystalClick::WidePart.w170_nullable_readback_probe = false
      FileUtils.rm_rf(root)
    end
  end

  it "materializes an OfflineTable base column and scans a separately typed temporal projection child" do
    root = File.tempname("crystal-click-simple-aggregate-temporal-w170-projection")
    begin
      profiles = W170SimpleAggregateTemporalTestSupport.accepted_profiles
      base = profiles.find do |candidate|
        candidate.leaf.storage_type_name == "Date32" && candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Max && !candidate.nullable
      end.not_nil!
      child = profiles.find do |candidate|
        candidate.leaf.storage_type_name == "DateTime64(9, '#{W170_TEMPORAL_LONGEST_ZONE}')" &&
          candidate.function == CrystalClick::BinarySimpleAggregateType::Function::Min && !candidate.nullable
      end.not_nil!
      base_values = W170SimpleAggregateTemporalTestSupport.library_values(base, Int32)
      child_values = W170SimpleAggregateTemporalTestSupport.library_values(child, Int64)
      base_part = File.join(root, "base", "all_1_1_0")
      child_part = File.join(root, "child", "all_1_1_0")
      w170_runtime_write_part(base, base_values, base_part)
      w170_runtime_write_part(child, child_values, child_part)
      catalog_root = File.join(root, "catalog")
      w170_runtime_create_catalog(catalog_root, base_part, base.type_name, 991, child_part)

      table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      table["v"].values(max_rows: 5_u64).map { |value| value.as(Int32) }.should eq(base_values)
      observed = [] of Int64
      table.scan_projection_typed("by_rollup", ["v"], batch_rows: 2) do |batch|
        batch.column_type_for("v").should eq(child.type_name)
        actual = batch.simple_aggregate_temporal_raw_values_for(
          "v", child.function, child.storage_type_name, Int64,
        ).to_a
        expected = child_values[batch.part_row_offset.to_i, actual.size]
        actual.should eq(expected)
        observed.concat(actual)
      end
      observed.should eq(child_values)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
