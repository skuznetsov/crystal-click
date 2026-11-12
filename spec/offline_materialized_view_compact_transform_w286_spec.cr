require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private def w286_compact_output(
  keys : Array(UInt64),
  values : Array(String),
  labels : Array(String),
) : CrystalClick::CompactPartTransformOutput
  value_rows = values.map { |value| CrystalClick::BinaryValue.string(value) }
  label_rows = labels.map { |value| CrystalClick::BinaryValue.string(value) }
  columns = [
    CrystalClick::CompactPartColumn.binary_bulk(
      "value",
      CrystalClick::BinaryDataType.primitive("String"),
      w286_binary_value_granules(value_rows),
    ),
    CrystalClick::CompactPartColumn.binary_bulk(
      "label",
      CrystalClick::BinaryDataType.primitive("String"),
      w286_binary_value_granules(label_rows),
    ),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), columns)
end

private def w286_binary_value_granules(values : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  granules = [] of Array(CrystalClick::BinaryValue)
  values.each_with_index do |value, index|
    granule_index = index // 2
    granules << [] of CrystalClick::BinaryValue if granule_index == granules.size
    granules[granule_index] << value
  end
  granules
end

private def w286_wide_output(keys : Array(UInt64)) : CrystalClick::WidePartTransformOutput
  columns = [
    CrystalClick::WidePartColumn.binary_bulk(
      "value",
      CrystalClick::BinaryDataType.primitive("String"),
      [[CrystalClick::BinaryValue.string("unreachable-value")]],
    ),
    CrystalClick::WidePartColumn.binary_bulk(
      "label",
      CrystalClick::BinaryDataType.primitive("String"),
      [[CrystalClick::BinaryValue.string("unreachable-label")]],
    ),
  ] of CrystalClick::WidePartColumn
  CrystalClick::WidePartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), columns)
end

private def w286_assert_no_publication(target_path : String) : Nil
  detached = File.join(target_path, "detached")
  Dir.children(detached).should be_empty
  nil
end

describe CrystalClick::OfflineCatalog do
  it "filters and rekeys Wide and Compact sources into both Compact mark formats" do
    {
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactMarkFormat::Mrk4,
    }.each do |mark_format|
      root = File.tempname("crystal-click-w286-compact-transform-#{mark_format}-")
      retained_input : CrystalClick::OfflinePartTransformInput? = nil
      begin
        target_tail = if mark_format.mrk3?
                        "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 1, min_bytes_for_wide_part = 1"
                      else
                        "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0"
                      end
        catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
          root,
          target_tail,
          compact_source: mark_format.mrk4?,
        )
        destination = File.join(target_path, "detached", "all_9_9_0")
        callback_count = 0
        batches = 0
        observed = [] of Tuple(UInt64, String)

        result = catalog.transform_materialized_view_part(
          "lab",
          "view",
          "all_1_1_0",
          ["k", "v"],
          "all_9_9_0",
          mark_format: mark_format,
          rows_per_mark: 2,
          batch_rows: 2,
          profile: mark_format.mrk4? ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream,
          frame_bytes: 64,
          limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
          transport_limits: CrystalClick::CompressedStreamLimits.new,
          reader_limits: CrystalClick::CompressedStreamLimits.new,
          variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
          compress_marks: mark_format.mrk4?,
        ) do |input|
          callback_count += 1
          retained_input = input
          input.column_names.should eq(["k", "v"])
          input.column_types.should eq([{"k", "UInt64"}, {"v", "String"}])
          input.row_count.should eq(4_u64)

          output_keys = [] of UInt64
          value_rows = [] of CrystalClick::BinaryValue
          label_rows = [] of CrystalClick::BinaryValue
          input.each_batch do |batch|
            batches += 1
            source_keys = batch.values_for("k")
            source_values = batch.strings_for("v")
            source_keys.each_with_index do |key, index|
              value = String.new(source_values[index].to_slice)
              observed << {key, value}
              next unless key > 1_u64
              output_keys << key * 10_u64
              value_rows << CrystalClick::BinaryValue.string("mapped-#{value}")
              label_rows << CrystalClick::BinaryValue.string("filtered-#{value}")
            end
          end

          columns = [
            CrystalClick::CompactPartColumn.binary_bulk(
              "value",
              CrystalClick::BinaryDataType.primitive("String"),
              value_granules = w286_binary_value_granules(value_rows),
            ),
            CrystalClick::CompactPartColumn.binary_bulk(
              "label",
              CrystalClick::BinaryDataType.primitive("String"),
              label_granules = w286_binary_value_granules(label_rows),
            ),
          ] of CrystalClick::CompactPartColumn
          output = CrystalClick::CompactPartTransformOutput.new(
            output_keys.to_unsafe.to_slice(output_keys.size),
            columns,
          )
          # Mutating every caller-owned container after construction must not
          # rewrite the detached output snapshot consumed after the callback.
          output_keys[0] = 999_u64
          value_granules[0][0] = CrystalClick::BinaryValue.string("caller-mutated-value")
          label_granules[0][0] = CrystalClick::BinaryValue.string("caller-mutated-label")
          columns.clear
          output
        end

        callback_count.should eq(1)
        batches.should eq(2)
        observed.should eq([
          {1_u64, "one"},
          {2_u64, "two"},
          {3_u64, "three"},
          {4_u64, "four"},
        ])
        result.should eq(destination)
        File.directory?(result).should be_true

        physical = CrystalClick::CompactPartPhysicalContext.open(result)
        physical.mode.should eq(mark_format)
        physical.granule_count.should eq(2)
        physical.row_count.should eq(3_u64)
        expected_mark_name = CrystalClick::CompactPhysicalMarkOutput.file_name(mark_format, mark_format.mrk4?)
        physical.marks_name.should eq(expected_mark_name)
        physical.columns.should eq([
          {"id", "UInt64"},
          {"value", "String"},
          {"label", "String"},
        ])

        reader = CrystalClick::TypedPartTable.open_selected_typed([result], ["id", "value", "label"])
        reader.column_types.should eq([
          {"id", "UInt64"},
          {"value", "String"},
          {"label", "String"},
        ])
        reader.part_mark_row_counts.should eq([[2_u64, 1_u64]])
        rows = [] of Tuple(UInt64, String, String)
        reader.scan_typed do |batch|
          keys = batch.values_for("id")
          values = batch.strings_for("value")
          labels = batch.strings_for("label")
          keys.each_with_index do |key, index|
            rows << {
              key,
              String.new(values[index].to_slice),
              String.new(labels[index].to_slice),
            }
          end
        end
        rows.should eq([
          {20_u64, "mapped-two", "filtered-two"},
          {30_u64, "mapped-three", "filtered-three"},
          {40_u64, "mapped-four", "filtered-four"},
        ])

        expect_raises(CrystalClick::UnsupportedFormatError) do
          retained_input.not_nil!.each_batch { |_batch| }
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects a Compact writer-valid value roster with the wrong name, order, or declaration" do
    mismatches = [
      {"wrong-name", {"not_value", "String"}, {"label", "String"}},
      {"wrong-order", {"label", "String"}, {"value", "String"}},
      {"wrong-declaration", {"value", "UInt64"}, {"label", "String"}},
    ] of Tuple(String, Tuple(String, String), Tuple(String, String))

    mismatches.each do |case_name, first, second|
      root = File.tempname("crystal-click-w286-compact-schema-#{case_name}-")
      begin
        catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
        destination = File.join(target_path, "detached", "all_9_9_0")
        columns = [first, second].map do |name, declaration|
          values = if declaration == "UInt64"
                     [CrystalClick::BinaryValue.uint64(200_u64)]
                   else
                     [CrystalClick::BinaryValue.string("writer-valid")]
                   end
          CrystalClick::CompactPartColumn.binary_bulk(
            name,
            CrystalClick::BinaryDataType.primitive(declaration),
            [values],
          )
        end

        # Prove this is a real admissible Compact writer roster, even though
        # the persisted target expects a different exact ordered schema.
        control = File.join(root, "valid-wrong-schema-control")
        CrystalClick::CompactPartWriter.write_uint64_columns(
          control,
          "id",
          Slice[20_u64],
          columns,
          rows_per_mark: 2,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        ).should eq(control)
        CrystalClick::CompactPartPhysicalContext.open(control).columns.should eq([
          {"id", "UInt64"},
          {first[0], first[1]},
          {second[0], second[1]},
        ])

        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            mark_format: CrystalClick::CompactMarkFormat::Mrk4,
            rows_per_mark: 2,
          ) do |input|
            input.each_batch { |_batch| }
            CrystalClick::CompactPartTransformOutput.new(
              Slice[20_u64],
              columns,
            )
          end
        end
        File.exists?(destination).should be_false
        w286_assert_no_publication(target_path)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects Compact target settings with an incomplete threshold pair before callback" do
    root = File.tempname("crystal-click-w286-compact-target-guard-")
    begin
      catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
        root,
        "ORDER BY id SETTINGS index_granularity = 2, min_rows_for_wide_part = 0",
      )
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          rows_per_mark: 2,
        ) do |_input|
          callbacks += 1
          w286_compact_output([20_u64], ["unreachable"], ["unreachable"])
        end
      end
      callbacks.should eq(0)
      w286_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unsupported nominal Compact target declarations before callback" do
    root = File.tempname("crystal-click-w286-compact-nominal-target-guard-")
    begin
      catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
        root,
        target_value_declaration: "QBit(Float32, 16)",
      )
      callbacks = 0
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          rows_per_mark: 2,
        ) do |input|
          callbacks += 1
          input.each_batch { |_batch| }
          w286_compact_output([20_u64], ["unreachable"], ["unreachable"])
        end
      end
      error.message.to_s.should contain("Compact selected type has no established typed batch carrier")
      callbacks.should eq(0)
      w286_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects incomplete scans and target metadata drift without stage residue" do
    root = File.tempname("crystal-click-w286-compact-incomplete-")
    begin
      catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          rows_per_mark: 2,
        ) do |_input|
          w286_compact_output([20_u64], ["not-published"], ["not-published"])
        end
      end
      w286_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end

    root = File.tempname("crystal-click-w286-compact-metadata-drift-")
    begin
      catalog, database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
      target_metadata = File.join(database_path, "target.sql")
      original_target_ddl = File.read(target_metadata)
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          rows_per_mark: 2,
        ) do |input|
          input.each_batch { |_batch| }
          File.write(target_metadata, original_target_ddl + "\n")
          w286_compact_output([20_u64], ["metadata-changed"], ["metadata-changed"])
        end
      end
      w286_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves a Compact destination collision introduced during the callback" do
    root = File.tempname("crystal-click-w286-compact-collision-")
    begin
      catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
      detached = File.join(target_path, "detached")
      destination = File.join(detached, "all_9_9_0")
      sentinel = File.join(detached, "untouched.sentinel")
      File.write(sentinel, "leave this sibling unchanged\n")

      expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          rows_per_mark: 2,
        ) do |input|
          input.each_batch { |_batch| }
          collision_columns = [
            CrystalClick::CompactPartColumn.binary_bulk(
              "value",
              CrystalClick::BinaryDataType.primitive("String"),
              [[CrystalClick::BinaryValue.string("preexisting-value")]],
            ),
            CrystalClick::CompactPartColumn.binary_bulk(
              "label",
              CrystalClick::BinaryDataType.primitive("String"),
              [[CrystalClick::BinaryValue.string("preexisting-label")]],
            ),
          ] of CrystalClick::CompactPartColumn
          CrystalClick::CompactPartWriter.write_uint64_columns(
            destination,
            "id",
            Slice[90_u64],
            collision_columns,
            rows_per_mark: 2,
            mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          )
          w286_compact_output([20_u64], ["transform-value"], ["transform-label"])
        end
      end

      File.exists?(destination).should be_true
      File.read(sentinel).should eq("leave this sibling unchanged\n")
      Dir.children(detached).sort.should eq(["all_9_9_0", "untouched.sentinel"])
      collision = CrystalClick::TypedPartTable.open_selected_typed(
        [destination], ["id", "value", "label"]
      )
      rows = [] of Tuple(UInt64, String, String)
      collision.scan_typed do |batch|
        keys = batch.values_for("id")
        values = batch.strings_for("value")
        labels = batch.strings_for("label")
        keys.each_with_index do |key, index|
          rows << {key, String.new(values[index].to_slice), String.new(labels[index].to_slice)}
        end
      end
      rows.should eq([{90_u64, "preexisting-value", "preexisting-label"}])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "invalidates an escaped input after nonlocal break from either transform layout" do
    {
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactMarkFormat::Mrk4,
    }.each do |mark_format|
      root = File.tempname("crystal-click-w286-compact-break-#{mark_format}-")
      retained_input : CrystalClick::OfflinePartTransformInput? = nil
      begin
        catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
        stopped = catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: mark_format,
          rows_per_mark: 2,
        ) do |input|
          retained_input = input
          input.each_batch { |_batch| } if mark_format.mrk4?
          break "compact-stopped" if input.row_count > 0_u64
          w286_compact_output([20_u64], ["unreachable"], ["unreachable"])
        end
        stopped.should eq("compact-stopped")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          retained_input.not_nil!.each_batch { |_batch| }
        end
        w286_assert_no_publication(target_path)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    root = File.tempname("crystal-click-w286-wide-break-")
    retained_input : CrystalClick::OfflinePartTransformInput? = nil
    begin
      catalog, _database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(root)
      stopped = catalog.transform_materialized_view_part(
        "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0", rows_per_mark: 2
      ) do |input|
        retained_input = input
        input.each_batch { |_batch| }
        break "wide-stopped" if input.row_count > 0_u64
        w286_wide_output([20_u64])
      end
      stopped.should eq("wide-stopped")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        retained_input.not_nil!.each_batch { |_batch| }
      end
      w286_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
