require "./spec_helper"
require "file_utils"

W257_TRANSFORM_DATABASE_UUID = "f2570000-7b7f-4e2f-9e44-dc13a87b8801"
W257_TRANSFORM_SOURCE_UUID   = "f2570000-7b7f-4e2f-9e44-dc13a87b8802"
W257_TRANSFORM_TARGET_UUID   = "f2570000-7b7f-4e2f-9e44-dc13a87b8803"
W257_TRANSFORM_VIEW_UUID     = "f2570000-7b7f-4e2f-9e44-dc13a87b8804"

private def w257_transform_database_path(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W257_TRANSFORM_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  path = File.join(root, "store", W257_TRANSFORM_DATABASE_UUID[0, 3], W257_TRANSFORM_DATABASE_UUID)
  FileUtils.mkdir_p(path)
  path
end

private def w257_transform_write_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  columns : String,
  tail : String,
) : String
  File.write(
    File.join(database_path, "#{name}.sql"),
    "ATTACH TABLE _ UUID '#{uuid}'\n(\n  #{columns}\n)\nENGINE = MergeTree\n#{tail}\n"
  )
  table_path = File.join(root, "store", uuid[0, 3], uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  table_path
end

private def w257_transform_catalog(
  root : String,
  target_tail : String = "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0",
  target_columns : String = "`id` UInt64, `value` String",
) : Tuple(CrystalClick::OfflineCatalog, String, String)
  database_path = w257_transform_database_path(root)
  source_path = w257_transform_write_table(
    root,
    database_path,
    "source",
    W257_TRANSFORM_SOURCE_UUID,
    "`k` UInt64, `v` String",
    "ORDER BY k SETTINGS index_granularity = 2"
  )
  target_path = w257_transform_write_table(
    root,
    database_path,
    "target",
    W257_TRANSFORM_TARGET_UUID,
    target_columns,
    target_tail
  )
  File.write(
    File.join(database_path, "view.sql"),
    <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W257_TRANSFORM_VIEW_UUID}' TO lab.target
    (
      `id` UInt64,
      `value` String
    )
    AS SELECT k, v FROM lab.source WHERE k > 1
    DDL
  )
  CrystalClick::WidePartWriter.write_uint64_typed_pair(
    File.join(source_path, "all_1_1_0"),
    "k",
    [1_u64, 2_u64, 3_u64, 4_u64].to_unsafe.to_slice(4),
    "v",
    ["one", "two", "three", "four"].to_unsafe.to_slice(4)
  )
  {CrystalClick::OfflineCatalog.open(root), database_path, target_path}
end

private def w257_transform_destination(target_path : String, part_name : String = "all_9_9_0") : String
  File.join(target_path, "detached", part_name)
end

private def w257_transform_output(keys : Array(UInt64), values : Array(String)) : CrystalClick::WidePartTransformOutput
  value_rows = values.map { |value| CrystalClick::BinaryValue.string(value) }
  columns = [CrystalClick::WidePartColumn.binary_bulk(
    "value",
    CrystalClick::BinaryDataType.primitive("String"),
    [value_rows] of Array(CrystalClick::BinaryValue)
  )]
  CrystalClick::WidePartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), columns)
end

private def w257_transform_assert_unpublished(path : String) : Nil
  File.exists?(path).should be_false
  File.symlink?(path).should be_false
end

private def w257_admission_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w257_admission_source_columns : String
  "`pk` UInt64, `payload` Dynamic(max_types=1), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"
end

private def w257_admission_write_source_part(path : String) : Nil
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)

  payloads = [
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(17_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(23_u64)),
  ] of CrystalClick::BinaryValue
  payload_column = CrystalClick::WidePartColumn.dynamic_bulk(
    "payload", dynamic, {"root" => dynamic_structure}, [payloads]
  )

  document_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  )
  document_plan = w257_admission_object_plan(document_schema)
  document = ->(value : UInt8) {
    CrystalClick::ObjectDocument.new({
      "t" => CrystalClick::BinaryValue.fixed(uint8, Bytes[value]),
    } of String => CrystalClick::BinaryValue)
  }
  recursive_schema = CrystalClick::StorageColumnSchema.parse(w257_admission_source_columns.split(", `trace` ")[1])
  recursive_dynamic = CrystalClick::BinaryDynamicBulkPlan.new(
    dynamic,
    {"root" => dynamic_structure},
    CrystalClick::BinaryBulkProfile.with_size_stream,
  )
  first = CrystalClick::StorageColumnValue.array([
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document.call(7_u8)),
      CrystalClick::StorageColumnValue.bulk(
        CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))
      ),
    ] of CrystalClick::StorageColumnValue),
  ] of CrystalClick::StorageColumnValue)
  second = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
  recursive_column = CrystalClick::WidePartColumn.recursive(
    "trace",
    recursive_schema,
    {"root/array[0]/tuple[0]" => document_plan},
    [[first, second]] of Array(CrystalClick::StorageColumnValue),
    {"root/array[0]/tuple[1]" => recursive_dynamic},
  )

  CrystalClick::WidePartWriter.write_uint64_columns(
    path,
    "pk",
    Slice[1_u64, 2_u64],
    [payload_column, recursive_column] of CrystalClick::WidePartColumn,
    rows_per_mark: 2,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
end

private def w257_admission_catalog(root : String, source_columns : String = w257_admission_source_columns) : Tuple(CrystalClick::OfflineCatalog, String, String)
  database_path = w257_transform_database_path(root)
  source_path = w257_transform_write_table(
    root,
    database_path,
    "source",
    W257_TRANSFORM_SOURCE_UUID,
    source_columns,
    "ORDER BY pk SETTINGS index_granularity = 2"
  )
  target_path = w257_transform_write_table(
    root,
    database_path,
    "target",
    W257_TRANSFORM_TARGET_UUID,
    "`id` UInt64, `value` UInt64",
    "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0"
  )
  File.write(
    File.join(database_path, "view.sql"),
    <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W257_TRANSFORM_VIEW_UUID}' TO lab.target
    (
      `id` UInt64,
      `value` UInt64
    )
    AS SELECT pk, pk FROM lab.source WHERE pk > 0
    DDL
  )
  w257_admission_write_source_part(File.join(source_path, "all_1_1_0"))
  {CrystalClick::OfflineCatalog.open(root), database_path, target_path}
end

private def w257_admission_output(keys : Array(UInt64), values : Array(UInt64)) : CrystalClick::WidePartTransformOutput
  binary_values = values.map { |value| CrystalClick::BinaryValue.uint64(value) }
  columns = [CrystalClick::WidePartColumn.binary_bulk(
    "value",
    CrystalClick::BinaryDataType.primitive("UInt64"),
    [binary_values],
  )] of CrystalClick::WidePartColumn
  CrystalClick::WidePartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), columns)
end

describe CrystalClick::OfflineCatalog do
  it "runs a full typed source scan, filters and computes output, then binds publication to the target" do
    root = File.tempname("crystal-click-w257-transform-positive-")
    retained_input : CrystalClick::OfflinePartTransformInput? = nil
    begin
      catalog, _database_path, target_path = w257_transform_catalog(root)
      destination = w257_transform_destination(target_path)
      callback_count = 0
      observed = [] of Tuple(UInt64, String)
      output_keys = [] of UInt64
      output_values = [] of String

      result = catalog.transform_materialized_view_part(
        "lab",
        "view",
        "all_1_1_0",
        ["k", "v"],
        "all_9_9_0",
        rows_per_mark: 2,
        batch_rows: 2
      ) do |input|
        callback_count += 1
        retained_input = input
        input.column_names.should eq(["k", "v"])
        input.column_types.should eq([{"k", "UInt64"}, {"v", "String"}])
        input.row_count.should eq(4_u64)
        input.each_batch do |batch|
          keys = batch.values_for("k")
          values = batch.strings_for("v")
          keys.size.should eq(values.size)
          keys.each_with_index do |key, index|
            value = String.new(values[index].to_slice)
            observed << {key, value}
            if key.odd?
              output_keys << key * 10
              output_values << "mapped-#{value}"
            end
          end
        end
        w257_transform_output(output_keys, output_values)
      end

      callback_count.should eq(1)
      observed.should eq([{1_u64, "one"}, {2_u64, "two"}, {3_u64, "three"}, {4_u64, "four"}])
      result.should eq(destination)
      File.directory?(result).should be_true
      File.read(File.join(result, "columns.txt")).should contain("`id` UInt64")
      File.read(File.join(result, "columns.txt")).should contain("`value` String")

      reader = CrystalClick::WidePartTable.open_selected_typed([result], ["id", "value"])
      reader.column_types.should eq([{"id", "UInt64"}, {"value", "String"}])
      rows = [] of Tuple(UInt64, String)
      reader.scan_typed do |batch|
        keys = batch.values_for("id")
        values = batch.strings_for("value")
        keys.each_with_index { |key, index| rows << {key, String.new(values[index].to_slice)} }
      end
      rows.should eq([{10_u64, "mapped-one"}, {30_u64, "mapped-three"}])

      expect_raises(CrystalClick::UnsupportedFormatError) do
        retained_input.not_nil!.each_batch { |_batch| }
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects an inadmissible target layout before invoking the caller" do
    root = File.tempname("crystal-click-w257-transform-target-layout-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(
        root,
        "PARTITION BY value ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0"
      )
      destination = w257_transform_destination(target_path)
      callback_count = 0

      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |_input|
          callback_count += 1
          w257_transform_output([10_u64], ["unreachable"])
        end
      end

      callback_count.should eq(0)
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects default or malformed target SETTINGS and column modifiers before callback" do
    invalid_tails = [
      "ORDER BY id",
      "ORDER BY id SETTINGS index_granularity = 3",
      "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, unknown_setting = 1",
      "ORDER BY id SETTINGS index_granularity = 2, index_granularity = 2",
      "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0",
    ]

    invalid_tails.each_with_index do |tail, index|
      root = File.tempname("crystal-click-w257-transform-settings-#{index}-")
      begin
        catalog, _database_path, target_path = w257_transform_catalog(root, tail)
        destination = w257_transform_destination(target_path)
        callback_count = 0

        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
          ) do |_input|
            callback_count += 1
            w257_transform_output([10_u64], ["unreachable"])
          end
        end

        callback_count.should eq(0)
        w257_transform_assert_unpublished(destination)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    root = File.tempname("crystal-click-w257-transform-column-modifier-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(
        root,
        "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0",
        "`id` UInt64, `value` String CODEC(ZSTD)"
      )
      destination = w257_transform_destination(target_path)
      callback_count = 0

      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |_input|
          callback_count += 1
          w257_transform_output([10_u64], ["unreachable"])
        end
      end

      callback_count.should eq(0)
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "does not publish when the callback omits or interrupts its required full scan" do
    root = File.tempname("crystal-click-w257-transform-incomplete-no-scan-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(root)
      destination = w257_transform_destination(target_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |_input|
          w257_transform_output([10_u64], ["not-published"])
        end
      end
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end

    root = File.tempname("crystal-click-w257-transform-incomplete-interrupted-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(root)
      destination = w257_transform_destination(target_path)
      expect_raises(ArgumentError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |input|
          input.each_batch do |_batch|
            raise ArgumentError.new("caller stopped after the first source batch")
          end
          w257_transform_output([10_u64], ["not-published"])
        end
      end
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a swallowed second scan and target DDL changes before publication" do
    root = File.tempname("crystal-click-w257-transform-protocol-")
    begin
      catalog, database_path, target_path = w257_transform_catalog(root)
      destination = w257_transform_destination(target_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |input|
          input.each_batch { |_batch| }
          begin
            input.each_batch { |_batch| }
          rescue CrystalClick::UnsupportedFormatError
            # Catching misuse must not restore the handle's publishable state.
          end
          w257_transform_output([10_u64], ["not-published"])
        end
      end
      w257_transform_assert_unpublished(destination)

      original_target_ddl = File.read(File.join(database_path, "target.sql"))
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |input|
          input.each_batch { |_batch| }
          File.write(File.join(database_path, "target.sql"), original_target_ddl + "\n")
          w257_transform_output([10_u64], ["metadata-changed"])
        end
      end
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rechecks the source and target candidate sets after the caller scan" do
    root = File.tempname("crystal-click-w257-transform-source-removed-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(root)
      source_part = File.join(root, "store", W257_TRANSFORM_SOURCE_UUID[0, 3], W257_TRANSFORM_SOURCE_UUID, "all_1_1_0")
      destination = w257_transform_destination(target_path)

      expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
        ) do |input|
          input.each_batch { |_batch| }
          FileUtils.rm_rf(source_part)
          w257_transform_output([10_u64], ["source-removed"])
        end
      end
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end

    root = File.tempname("crystal-click-w257-transform-target-overlap-")
    begin
      catalog, _database_path, target_path = w257_transform_catalog(root)
      destination = w257_transform_destination(target_path, "all_20_20_0")

      expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_20_20_0", rows_per_mark: 2
        ) do |input|
          input.each_batch { |_batch| }
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            File.join(target_path, "all_7_9_0"),
            "id",
            [7_u64, 9_u64].to_unsafe.to_slice(2),
            "value",
            ["seven", "nine"].to_unsafe.to_slice(2)
          )
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            File.join(target_path, "all_8_10_0"),
            "id",
            [8_u64, 10_u64].to_unsafe.to_slice(2),
            "value",
            ["eight", "ten"].to_unsafe.to_slice(2)
          )
          w257_transform_output([20_u64], ["target-overlap"])
        end
      end
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "hands exact Dynamic and mixed recursive JSON/Dynamic declarations to the existing typed reader" do
    root = File.tempname("crystal-click-w257-transform-selection-admission-")
    begin
      catalog, _database_path, target_path = w257_admission_catalog(root)
      destination = w257_transform_destination(target_path)
      callback_count = 0
      transformed_keys = [] of UInt64
      transformed_values = [] of UInt64

      result = catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["pk", "payload", "trace"], "all_9_9_0",
        rows_per_mark: 2, batch_rows: 2
      ) do |input|
        callback_count += 1
        input.column_types.should eq([
          {"pk", "UInt64"},
          {"payload", "Dynamic(max_types=1)"},
          {"trace", "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"},
        ])
        input.row_count.should eq(2_u64)

        input.each_batch do |batch|
          keys = batch.values_for("pk")
          payloads = batch.dynamic_bulk_values_for("payload")
          traces = batch.recursive_values_for("trace")
          keys.size.should eq(payloads.size)
          keys.size.should eq(traces.size)
          payloads[0].child_at(0).as_uint64.should eq(17_u64)
          payloads[1].child_at(0).as_uint64.should eq(23_u64)
          trace = traces[0].array_values
          trace.size.should eq(1)
          trace[0].child_at(0).object_document.value_for("t").byte_at(0).should eq(7_u8)
          trace[0].child_at(1).bulk_value.child_at(0).as_uint64.should eq(11_u64)
          traces[1].array_values.should be_empty

          keys.each_with_index do |key, index|
            transformed_keys << key * 10_u64
            transformed_values << payloads[index].child_at(0).as_uint64
          end
        end

        w257_admission_output(transformed_keys, transformed_values)
      end

      callback_count.should eq(1)
      result.should eq(destination)
      File.directory?(destination).should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "normalizes whitespace-only Dynamic DDL through transform and reads native output" do
    root = File.tempname("crystal-click-w257-transform-dynamic-whitespace-")
    begin
      source_columns = w257_admission_source_columns.gsub(
        "`payload` Dynamic(max_types=1)",
        "`payload` Dynamic(max_types=1 )"
      )
      source_columns.should contain("`payload` Dynamic(max_types=1 )")
      source_columns.should_not contain("`payload` Dynamic(max_types=1),")
      catalog, _database_path, target_path = w257_admission_catalog(root, source_columns)
      payload_column = catalog.table("lab", "source").columns.find { |column| column.name == "payload" }
      payload_column.not_nil!.type.should eq("Dynamic(max_types=1 )")
      destination = w257_transform_destination(target_path)
      callback_count = 0
      transformed_keys = [] of UInt64
      transformed_values = [] of UInt64

      result = catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["pk", "payload"], "all_9_9_0",
        rows_per_mark: 2, batch_rows: 2
      ) do |input|
        callback_count += 1
        input.column_types.should eq([
          {"pk", "UInt64"},
          {"payload", "Dynamic(max_types=1)"},
        ])
        input.row_count.should eq(2_u64)

        input.each_batch do |batch|
          keys = batch.values_for("pk")
          payloads = batch.dynamic_bulk_values_for("payload")
          keys.size.should eq(payloads.size)
          keys.each_with_index do |key, index|
            transformed_keys << key * 10_u64
            transformed_values << payloads[index].child_at(0).as_uint64 * 10_u64
          end
        end

        w257_admission_output(transformed_keys, transformed_values)
      end

      callback_count.should eq(1)
      result.should eq(destination)
      File.directory?(result).should be_true

      reader = CrystalClick::WidePartTable.open_selected_typed([result], ["id", "value"])
      reader.column_types.should eq([{"id", "UInt64"}, {"value", "UInt64"}])
      rows = [] of Tuple(UInt64, UInt64)
      reader.scan_typed do |batch|
        keys = batch.values_for("id")
        values = batch.values_for("value")
        keys.size.should eq(values.size)
        keys.each_with_index { |key, index| rows << {key, values[index]} }
      end
      rows.should eq([{10_u64, 170_u64}, {20_u64, 230_u64}])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps canonical, nominal, alias, DDL/part, and JSON-path ambiguity guards before callback" do
    cases = [
      {
        "explicit Dynamic default cap",
        "`pk` UInt64, `payload` Dynamic(max_types=32), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))",
        ["pk", "payload"] of String,
        "selected table column type is unsupported",
      },
      {
        "unsupported nullable Dynamic owner",
        "`pk` UInt64, `payload` Nullable(Dynamic(max_types=1)), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))",
        ["pk", "payload"] of String,
        "selected table column type is unsupported",
      },
      {
        "DDL and part Dynamic declarations differ",
        "`pk` UInt64, `payload` Dynamic(max_types=2), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))",
        ["pk", "payload"] of String,
        "table DDL and selected part column types differ",
      },
      {
        "unsupported nullable Dynamic below a mixed recursive JSON tree",
        "`pk` UInt64, `payload` Dynamic(max_types=1), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Nullable(Dynamic(max_types=1))))",
        ["pk", "trace"] of String,
        "selected table column type is unsupported",
      },
      {
        "selected Dynamic source is an ALIAS",
        "`pk` UInt64, `payload` Dynamic(max_types=1) ALIAS pk, `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))",
        ["pk", "payload"] of String,
        "ALIAS",
      },
      {
        "selected virtual JSON path has an ALIAS parent",
        "`pk` UInt64, `payload` Dynamic(max_types=1), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1))), `doc` JSON(t UInt8) ALIAS pk",
        ["doc.t"] of String,
        "ALIAS",
      },
      {
        "typed JSON path collides with a literal dotted column",
        "`pk` UInt64, `payload` Dynamic(max_types=1), `trace` Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1))), `doc` JSON(t UInt8), `doc.t` UInt8",
        ["doc.t"] of String,
        "ambiguous between a literal dotted column and a JSON typed path",
      },
    ] of Tuple(String, String, Array(String), String)

    cases.each_with_index do |(label, source_columns, selection, expected_message), index|
      root = File.tempname("crystal-click-w257-transform-selection-guard-#{index}-")
      begin
        catalog, _database_path, target_path = w257_admission_catalog(root, source_columns)
        destination = w257_transform_destination(target_path)
        callback_count = 0
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", selection, "all_9_9_0", rows_per_mark: 2
          ) do |_input|
            callback_count += 1
            w257_admission_output([10_u64], [10_u64])
          end
        end

        (error.message || "").should contain(expected_message)
        callback_count.should eq(0)
        w257_transform_assert_unpublished(destination)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects an unsupported nominal leaf below a mixed recursive JSON tree before callback" do
    root = File.tempname("crystal-click-w257-transform-recursive-nominal-leaf-")
    begin
      catalog, database_path, target_path = w257_admission_catalog(root)
      source_ddl_path = File.join(database_path, "source.sql")
      source_ddl = File.read(source_ddl_path)
      source_ddl.should contain("sample Dynamic(max_types=1)")
      File.write(
        source_ddl_path,
        source_ddl.gsub("sample Dynamic(max_types=1)", "sample AggregateFunction(uniq, UInt64)")
      )

      destination = w257_transform_destination(target_path)
      callback_count = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["pk", "trace"], "all_9_9_0", rows_per_mark: 2
        ) do |_input|
          callback_count += 1
          w257_admission_output([10_u64], [10_u64])
        end
      end

      callback_count.should eq(0)
      w257_transform_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
