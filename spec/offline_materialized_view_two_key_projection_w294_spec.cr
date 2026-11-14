require "./spec_helper"
require "file_utils"
require "json"
require "./support/offline_materialized_view_compact_transform_w286_fixture"
require "./support/projection_checksum_fixture"

private alias W294Aggregate = CrystalClick::WidePartProjectionAggregate

private def w294_catalog(root : String, projection : String? = nil)
  _, database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
    root, target_value_declaration: "UInt64"
  )
  target_metadata = File.join(database_path, "target.sql")
  projection_clause = projection.try { |value| ",\n  PROJECTION `by_pair` (#{value})" } || ""
  target_ddl = File.read(target_metadata)
    .sub("`id` UInt64, `value`", "`id` UInt64, `region` UInt64, `day` UInt64, `value`")
    .sub("`label` String\n)", "`label` String#{projection_clause}\n)")
  File.write(target_metadata, target_ddl)

  view_metadata = File.join(database_path, "view.sql")
  view_ddl = File.read(view_metadata)
    .sub(
      "`id` UInt64,\n",
      "`id` UInt64,\n        `region` UInt64,\n        `day` UInt64,\n"
    )
    .sub("AS SELECT k, v, v FROM lab.source", "AS SELECT k, k, k, k, v FROM lab.source")
  File.write(view_metadata, view_ddl)
  {CrystalClick::OfflineCatalog.open(root), target_path}
end

private def w294_aggregate_columns(order : Symbol) : Array(W294Aggregate)
  sum = W294Aggregate.sum_uint64(
    "value", Slice[100_u64, 200_u64, 300_u64, 400_u64, 500_u64, 600_u64]
  )
  count = W294Aggregate.count(Slice[1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64])
  maximum = W294Aggregate.max_uint64("id", Slice[10_u64, 11_u64, 20_u64, 21_u64, 30_u64, 40_u64])
  case order
  when :sum_count_max    then [sum, count, maximum]
  when :max_count_sum    then [maximum, count, sum]
  when :max_sum_no_count then [maximum, sum]
  else                        raise "unexpected W294 aggregate order"
  end
end

private def w294_projection(
  regions : Array(UInt64),
  days : Array(UInt64),
  aggregates : Array(W294Aggregate),
  key_names : Tuple(String, String) = {"region", "day"},
) : CrystalClick::WidePartProjection
  CrystalClick::WidePartProjection.precomputed_aggregate(
    "by_pair",
    key_names,
    {
      regions.to_unsafe.to_slice(regions.size),
      days.to_unsafe.to_slice(days.size),
    },
    aggregates,
    rows_per_mark: 2,
  )
end

private def w294_key_arrays : Tuple(Array(UInt64), Array(UInt64))
  {
    [10_u64, 10_u64, 10_u64, 10_u64, 11_u64, 11_u64],
    [1_u64, 2_u64, 3_u64, 4_u64, 1_u64, 2_u64],
  }
end

private def w294_granules(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  granules = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(2) { |slice| granules << slice.to_a }
  granules
end

private def w294_parent(input : CrystalClick::OfflinePartTransformInput) : Tuple(
  Array(UInt64),
  Array(Tuple(String, CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)))),
)
  ids = [] of UInt64
  regions = [] of CrystalClick::BinaryValue
  days = [] of CrystalClick::BinaryValue
  values = [] of CrystalClick::BinaryValue
  labels = [] of CrystalClick::BinaryValue

  input.each_batch do |batch|
    source_keys = batch.values_for("k")
    source_values = batch.strings_for("v")
    source_keys.each_with_index do |key, index|
      label = String.new(source_values[index].to_slice)
      case key
      when 1_u64
        ids << 10_u64
        regions << CrystalClick::BinaryValue.uint64(10_u64)
        days << CrystalClick::BinaryValue.uint64(1_u64)
        values << CrystalClick::BinaryValue.uint64(100_u64)
        labels << CrystalClick::BinaryValue.string(label)

        ids << 11_u64
        regions << CrystalClick::BinaryValue.uint64(10_u64)
        days << CrystalClick::BinaryValue.uint64(2_u64)
        values << CrystalClick::BinaryValue.uint64(200_u64)
        labels << CrystalClick::BinaryValue.string(label)
      when 2_u64
        ids << 20_u64
        regions << CrystalClick::BinaryValue.uint64(10_u64)
        days << CrystalClick::BinaryValue.uint64(3_u64)
        values << CrystalClick::BinaryValue.uint64(300_u64)
        labels << CrystalClick::BinaryValue.string(label)

        ids << 21_u64
        regions << CrystalClick::BinaryValue.uint64(10_u64)
        days << CrystalClick::BinaryValue.uint64(4_u64)
        values << CrystalClick::BinaryValue.uint64(400_u64)
        labels << CrystalClick::BinaryValue.string(label)
      when 3_u64
        ids << 30_u64
        regions << CrystalClick::BinaryValue.uint64(11_u64)
        days << CrystalClick::BinaryValue.uint64(1_u64)
        values << CrystalClick::BinaryValue.uint64(500_u64)
        labels << CrystalClick::BinaryValue.string(label)
      when 4_u64
        ids << 40_u64
        regions << CrystalClick::BinaryValue.uint64(11_u64)
        days << CrystalClick::BinaryValue.uint64(2_u64)
        values << CrystalClick::BinaryValue.uint64(600_u64)
        labels << CrystalClick::BinaryValue.string(label)
      else
        raise "unexpected W294 source key"
      end
    end
  end

  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  string = CrystalClick::BinaryDataType.primitive("String")
  columns = [
    {"region", uint64, regions},
    {"day", uint64, days},
    {"value", uint64, values},
    {"label", string, labels},
  ]
  granules = columns.map do |name, type, rows|
    {name, type, w294_granules(rows)}
  end
  {ids, granules}
end

private def w294_transform(
  catalog : CrystalClick::OfflineCatalog,
  projection : CrystalClick::WidePartProjection?,
  compact_parent : Bool = false,
) : String
  projections = projection.try { |value| [value] } || [] of CrystalClick::WidePartProjection
  if compact_parent
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2, mark_format: CrystalClick::CompactMarkFormat::Mrk3,
    ) do |input|
      ids, columns = w294_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::CompactPartTransformOutput.new(
        ids.to_unsafe.to_slice(ids.size), prepared, projections: projections
      )
    end
  else
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2,
    ) do |input|
      ids, columns = w294_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::WidePartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::WidePartTransformOutput.new(
        ids.to_unsafe.to_slice(ids.size), prepared, projections: projections
      )
    end
  end
end

private def w294_publish(
  root : String,
  ddl : String,
  order : Symbol,
  compact_parent : Bool,
  mutate_inputs : Bool = false,
) : Tuple(CrystalClick::OfflineCatalog, String, String)
  catalog, target = w294_catalog(root, ddl)
  regions, days = w294_key_arrays
  aggregate_columns = w294_aggregate_columns(order)
  projection = w294_projection(regions, days, aggregate_columns)
  if mutate_inputs
    regions.fill(999_u64)
    days.fill(0_u64)
    aggregate_columns.clear
  end
  destination = w294_transform(catalog, projection, compact_parent)
  attached = File.join(target, "all_9_9_0")
  File.rename(destination, attached)
  {catalog, target, attached}
end

private def w294_u64_bytes(values : Array(UInt64)) : Bytes
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times do |offset|
      bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8
    end
  end
  bytes
end

private def w294_default_record_names(child : String) : Array(String)
  JSON.parse(File.read(File.join(child, "serialization.json"))).as_h["columns"].as_a
    .select { |entry| entry.as_h["kind"].as_s == "Default" }
    .map { |entry| entry.as_h["name"].as_s }
end

private def w294_stock_key_serialization : String
  "{\"columns\":[{\"kind\":\"Default\",\"name\":\"day\",\"num_defaults\":0,\"num_rows\":6,\"exact_num_defaults\":true},{\"kind\":\"Default\",\"name\":\"region\",\"num_defaults\":0,\"num_rows\":6,\"exact_num_defaults\":true}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
end

private def w294_assert_child_binding(parent : String) : Nil
  child = File.join(parent, "by_pair.proj")
  summary = CrystalClick::ProjectionChecksumSummary.new(CrystalClick::PartChecksums.open(child))
  entry = CrystalClick::PartChecksums.open(parent).entry("by_pair.proj").not_nil!
  entry.physical_size.should eq(summary.total_size_on_disk)
  entry.file_hash.should eq(summary.total_checksum)
  entry.compressed.should be_false
end

private def w294_reseal_child_serialization!(parent : String, replacement : String) : Nil
  child = File.join(parent, "by_pair.proj")
  serialization_path = File.join(child, "serialization.json")
  File.write(serialization_path, replacement)
  bytes = File.read(serialization_path).to_slice
  records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
  CrystalClick::PartChecksums.open(child).entries.each do |name, entry|
    if name == "serialization.json"
      records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
        name, bytes.size.to_u64, CrystalClick::CityHashV1.file_hash(bytes), false
      )
    else
      records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
        name, entry.physical_size, entry.file_hash, entry.compressed,
        entry.uncompressed_size, entry.uncompressed_hash
      )
    end
  end
  CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(child, records)
  ProjectionChecksumFixture.rebind!(parent, "by_pair")
end

private def w294_assert_unpublished(target : String) : Nil
  Dir.children(File.join(target, "detached")).should be_empty
end

describe "W294 caller-run two-key UInt64 aggregate projections" do
  it "writes key-first compound Wide children under both native parent layouts" do
    [
      {
        false,
        "SELECT day, sum(value) AS total, region, count() AS n, max(id) AS last_id GROUP BY region, day",
        :sum_count_max,
        ["`region` UInt64", "`day` UInt64", "`sum(value)` AggregateFunction(sum, UInt64)", "`count()` AggregateFunction(count)", "`max(id)` AggregateFunction(max, UInt64)"],
        ["region", "day", "sum(value)", "count()", "max(id)"],
      },
      {
        true,
        "SELECT max(id) AS last_id, count() AS n, sum(value) AS total GROUP BY region, day",
        :max_count_sum,
        ["`region` UInt64", "`day` UInt64", "`max(id)` AggregateFunction(max, UInt64)", "`count()` AggregateFunction(count)", "`sum(value)` AggregateFunction(sum, UInt64)"],
        ["region", "day", "max(id)", "count()", "sum(value)"],
      },
    ].each do |compact_parent, ddl, order, expected_declarations, selected_columns|
      root = File.tempname("crystal-click-w294-layout-")
      begin
        catalog, target, attached = w294_publish(root, ddl, order, compact_parent, mutate_inputs: true)
        if compact_parent
          physical = CrystalClick::CompactPartPhysicalContext.open(attached)
          physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
          physical.row_count.should eq(6_u64)
        else
          File.exists?(File.join(attached, "#{CrystalClick::StreamName.hash("id")}.bin")).should be_true
          File.exists?(File.join(attached, "data.bin")).should be_false
        end

        child = File.join(attached, "by_pair.proj")
        File.read_lines(File.join(child, "columns.txt"))[2..].should eq(expected_declarations)
        File.exists?(File.join(child, "data.bin")).should be_false
        File.exists?(File.join(child, "#{CrystalClick::StreamName.hash("region")}.bin")).should be_true
        File.exists?(File.join(child, "#{CrystalClick::StreamName.hash("day")}.bin")).should be_true

        # Crystal's normalized writer omits per-column stats. The stock two-key
        # roster is exercised below with a resealed synthetic child.
        JSON.parse(File.read(File.join(child, "serialization.json"))).as_h["columns"].as_a.should be_empty

        index_pairs = [10_u64, 1_u64, 10_u64, 3_u64, 11_u64, 1_u64, 11_u64, 2_u64]
        File.read(File.join(child, "primary.idx")).to_slice.to_a.should eq(w294_u64_bytes(index_pairs).to_a)

        direct = CrystalClick::WidePartTable.open_selected_projection_typed(
          [attached], "by_pair", selected_columns
        )
        direct.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])

        table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
        observed_regions = [] of UInt64
        observed_days = [] of UInt64
        sums = [] of String
        maxima = [] of String
        counts = [] of UInt64
        table.scan_projection_typed("by_pair", selected_columns, batch_rows: 2) do |batch|
          observed_regions.concat(batch.values_for("region"))
          observed_days.concat(batch.values_for("day"))
          sums.concat(batch.binary_bulk_values_for("sum(value)").map { |state| state.aggregate_function_state_bytes.hexstring })
          maxima.concat(batch.binary_bulk_values_for("max(id)").map { |state| state.aggregate_function_state_bytes.hexstring })
          counts.concat(
            batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count).map(&.count_state)
          )
        end
        observed_regions.should eq([10_u64, 10_u64, 10_u64, 10_u64, 11_u64, 11_u64])
        observed_days.should eq([1_u64, 2_u64, 3_u64, 4_u64, 1_u64, 2_u64])
        sums.should eq([100_u64, 200_u64, 300_u64, 400_u64, 500_u64, 600_u64].map { |value| w294_u64_bytes([value]).hexstring })
        maxima.should eq([10_u64, 11_u64, 20_u64, 21_u64, 30_u64, 40_u64].map { |value| "01" + w294_u64_bytes([value]).hexstring })
        counts.should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64])

        if compact_parent
          # Count-only selection still admits both hidden group-key lanes. The
          # parent checksum binding remains valid after only the second key's
          # physical files are truncated, so this must fail during admission.
          w294_assert_child_binding(attached)
          parent_manifest = File.read(File.join(attached, "checksums.txt"))
          child_manifest = File.read(File.join(child, "checksums.txt"))
          ["#{CrystalClick::StreamName.hash("day")}.bin", "#{CrystalClick::StreamName.hash("day")}.mrk2"].each do |name|
            File.write(File.join(child, name), Bytes.new(0))
          end
          File.read(File.join(attached, "checksums.txt")).should eq(parent_manifest)
          File.read(File.join(child, "checksums.txt")).should eq(child_manifest)
          w294_assert_child_binding(attached)

          callbacks = 0
          error = expect_raises(CrystalClick::CorruptPartError) do
            table.scan_projection_typed("by_pair", ["count()"], batch_rows: 2) do |_batch|
              callbacks += 1
            end
          end
          error.message.should eq("mark file is empty or truncated")
          callbacks.should eq(0)
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "writes and reads a two-key aggregate projection without Count" do
    root = File.tempname("crystal-click-w294-no-count-")
    begin
      ddl = "SELECT max(id) AS last_id, sum(value) AS total GROUP BY region, day"
      catalog, target = w294_catalog(root, ddl)
      regions, days = w294_key_arrays
      projection = w294_projection(regions, days, w294_aggregate_columns(:max_sum_no_count))
      destination = w294_transform(catalog, projection)
      attached = File.join(target, "all_9_9_0")
      File.rename(destination, attached)

      child = File.join(attached, "by_pair.proj")
      File.read_lines(File.join(child, "columns.txt"))[2..].should eq([
        "`region` UInt64",
        "`day` UInt64",
        "`max(id)` AggregateFunction(max, UInt64)",
        "`sum(value)` AggregateFunction(sum, UInt64)",
      ])
      JSON.parse(File.read(File.join(child, "serialization.json"))).as_h["columns"].as_a.should be_empty

      table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
      observed_regions = [] of UInt64
      observed_days = [] of UInt64
      maxima = [] of String
      sums = [] of String
      table.scan_projection_typed(
        "by_pair", ["region", "day", "max(id)", "sum(value)"], batch_rows: 2
      ) do |batch|
        observed_regions.concat(batch.values_for("region"))
        observed_days.concat(batch.values_for("day"))
        maxima.concat(batch.binary_bulk_values_for("max(id)").map { |state| state.aggregate_function_state_bytes.hexstring })
        sums.concat(batch.binary_bulk_values_for("sum(value)").map { |state| state.aggregate_function_state_bytes.hexstring })
      end
      observed_regions.should eq([10_u64, 10_u64, 10_u64, 10_u64, 11_u64, 11_u64])
      observed_days.should eq([1_u64, 2_u64, 3_u64, 4_u64, 1_u64, 2_u64])
      maxima.should eq([10_u64, 11_u64, 20_u64, 21_u64, 30_u64, 40_u64].map { |value| "01" + w294_u64_bytes([value]).hexstring })
      sums.should eq([100_u64, 200_u64, 300_u64, 400_u64, 500_u64, 600_u64].map { |value| w294_u64_bytes([value]).hexstring })
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps the ordinary nonprojection Wide and Compact parent control intact" do
    [false, true].each do |compact_parent|
      root = File.tempname("crystal-click-w294-ordinary-#{compact_parent}-")
      begin
        catalog, target = w294_catalog(root)
        destination = w294_transform(catalog, nil, compact_parent)
        attached = File.join(target, "all_9_9_0")
        File.rename(destination, attached)
        File.directory?(File.join(attached, "by_pair.proj")).should be_false
        File.read(File.join(attached, "primary.idx")).to_slice.to_a.should eq(
          w294_u64_bytes([10_u64, 20_u64, 30_u64, 40_u64]).to_a
        )
        if compact_parent
          physical = CrystalClick::CompactPartPhysicalContext.open(attached)
          physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
          physical.columns.should eq([
            {"id", "UInt64"},
            {"region", "UInt64"},
            {"day", "UInt64"},
            {"value", "UInt64"},
            {"label", "String"},
          ])
        end

        table = CrystalClick::TypedPartTable.open_selected_typed(
          [attached], ["id", "region", "day", "value", "label"]
        )
        table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64]])
        ids = [] of UInt64
        values = [] of UInt64
        labels = [] of String
        table.scan_typed do |batch|
          ids.concat(batch.values_for("id"))
          values.concat(batch.values_for("value"))
          batch.strings_for("label").each { |bytes| labels << String.new(bytes.to_slice) }
        end
        ids.should eq([10_u64, 11_u64, 20_u64, 21_u64, 30_u64, 40_u64])
        values.should eq([100_u64, 200_u64, 300_u64, 400_u64, 500_u64, 600_u64])
        labels.size.should eq(6)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects duplicate, descending, and mismatched pair grids while retaining snapshots" do
    regions, days = w294_key_arrays
    aggregate_columns = w294_aggregate_columns(:sum_count_max)
    projection = w294_projection(regions, days, aggregate_columns)
    regions.fill(999_u64)
    days.fill(0_u64)
    aggregate_columns.clear
    projection.key_names.should eq(["region", "day"])
    projection.keys.should eq([10_u64, 10_u64, 10_u64, 10_u64, 11_u64, 11_u64])
    projection.secondary_keys.should eq([1_u64, 2_u64, 3_u64, 4_u64, 1_u64, 2_u64])
    projection.aggregate_columns.size.should eq(3)

    invalid_pairs = [
      {[10_u64, 10_u64], [1_u64, 1_u64]},
      {[10_u64, 10_u64], [2_u64, 1_u64]},
      {[11_u64, 10_u64], [1_u64, 9_u64]},
    ]
    invalid_pairs.each do |first, second|
      values = Array(UInt64).new(first.size, 1_u64)
      expect_raises(ArgumentError) do
        w294_projection(
          first, second,
          [W294Aggregate.count(values.to_unsafe.to_slice(values.size))]
        )
      end
    end

    values = Array(UInt64).new(2, 1_u64)
    expect_raises(ArgumentError) do
      w294_projection(
        [10_u64, 11_u64], [1_u64],
        [W294Aggregate.count(values.to_unsafe.to_slice(values.size))]
      )
    end
  end

  it "rejects unsupported key DDL before calling the transform callback" do
    [
      "SELECT count() GROUP BY region, label",
      "SELECT count() GROUP BY region, region",
      "SELECT count() GROUP BY region, day, id",
      "SELECT count() GROUP BY region + 1, day",
    ].each do |ddl|
      root = File.tempname("crystal-click-w294-invalid-ddl-")
      begin
        catalog, target = w294_catalog(root, ddl)
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            rows_per_mark: 2, batch_rows: 1,
          ) do |_input|
            callbacks += 1
            raise "invalid W294 projection reached callback"
          end
        end
        callbacks.should eq(0)
        w294_assert_unpublished(target)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects swapped key owners and Count totals before publishing a child" do
    ddl = "SELECT count() AS n, sum(value) AS total GROUP BY region, day"
    root = File.tempname("crystal-click-w294-invalid-owner-")
    begin
      catalog, target = w294_catalog(root, ddl)
      aggregates = w294_aggregate_columns(:sum_count_max)[0..1]
      swapped = w294_projection(
        [1_u64, 1_u64, 2_u64, 2_u64, 3_u64, 4_u64],
        [10_u64, 11_u64, 10_u64, 11_u64, 10_u64, 10_u64],
        aggregates,
        {"day", "region"},
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w294_transform(catalog, swapped)
      end
      w294_assert_unpublished(target)

      regions, days = w294_key_arrays
      wrong_counts = W294Aggregate.count(Slice[1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 2_u64])
      wrong_total = w294_projection(
        regions, days,
        [w294_aggregate_columns(:sum_count_max)[0], wrong_counts]
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w294_transform(catalog, wrong_total)
      end
      w294_assert_unpublished(target)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "accepts a complete name-ordered stock key roster and rejects duplicate or incomplete rosters" do
    root = File.tempname("crystal-click-w294-stock-serializer-roster-")
    begin
      ddl = "SELECT max(id) AS last_id, count() AS n, sum(value) AS total GROUP BY region, day"
      _catalog, _target, attached = w294_publish(root, ddl, :max_count_sum, true)
      child = File.join(attached, "by_pair.proj")
      JSON.parse(File.read(File.join(child, "serialization.json"))).as_h["columns"].as_a.should be_empty
      stock_serialization = w294_stock_key_serialization
      w294_reseal_child_serialization!(attached, stock_serialization)
      w294_default_record_names(child).should eq(["day", "region"])
      w294_assert_child_binding(attached)

      callbacks = 0
      counts = [] of UInt64
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
      table.scan_projection_typed("by_pair", ["count()"], batch_rows: 2) do |batch|
        callbacks += 1
        counts.concat(
          batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count).map(&.count_state)
        )
      end
      callbacks.should eq(3)
      counts.should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64])
    ensure
      FileUtils.rm_rf(root)
    end

    [
      {
        :duplicate,
        ->(source : String) { source.sub("\"name\":\"region\"", "\"name\":\"day\"") },
      },
      {
        :incomplete,
        ->(source : String) { source.gsub(/,\{"kind":"Default","name":"region"[^}]*\}/, "") },
      },
    ].each do |mutation, mutate|
      root = File.tempname("crystal-click-w294-serializer-roster-")
      begin
        ddl = "SELECT max(id) AS last_id, count() AS n, sum(value) AS total GROUP BY region, day"
        _catalog, _target, attached = w294_publish(root, ddl, :max_count_sum, true)
        child = File.join(attached, "by_pair.proj")
        w294_reseal_child_serialization!(attached, w294_stock_key_serialization)
        replacement = mutate.call(w294_stock_key_serialization)
        replacement.should_not eq(w294_stock_key_serialization)
        w294_reseal_child_serialization!(attached, replacement)
        w294_assert_child_binding(attached)

        callbacks = 0
        table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_projection_typed("by_pair", ["count()"], batch_rows: 2) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
