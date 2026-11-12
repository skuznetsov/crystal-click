require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_json_recursive_public_w263_fixture"
require "./support/compact_json_recursive_public_w263_mutant_fixture"

ENV["CRYSTAL_CLICK_W263_EVIDENCE_ROOT"]? ||
  raise "CRYSTAL_CLICK_W263_EVIDENCE_ROOT must name the authenticated baseline capture"

describe "W263 recursive/public Compact JSON adversaries" do
  fixture = CompactJsonRecursivePublicW263MutantFixture
  expected = CompactJsonRecursivePublicW263Fixture.expected_signatures

  it "admits the bounded recursive Object/Array/Tuple/UInt8 subset" do
    object = CrystalClick::StorageColumnSchema.object(
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON"),
      "JSON",
    )
    admitted = [
      object,
      CrystalClick::StorageColumnSchema.parse("Array(JSON)"),
      CrystalClick::StorageColumnSchema.parse("Array(Array(JSON))"),
      CrystalClick::StorageColumnSchema.parse("Array(Tuple(JSON, UInt8))"),
      CrystalClick::StorageColumnSchema.parse("Tuple(JSON, JSON)"),
      CrystalClick::StorageColumnSchema.parse("Tuple(Array(JSON), Array(JSON))"),
      CrystalClick::StorageColumnSchema.parse("Tuple(JSON, UInt8)"),
      CrystalClick::StorageColumnSchema.parse("Array(Tuple(UInt8, JSON))"),
      CrystalClick::StorageColumnSchema.parse("Tuple(JSON, Dynamic(max_types=8))"),
      # W283 expands the recursive JSON owner only; this JSON-free Variant
      # Bulk sibling remains outside the shared prefix-free admission gate.
      CrystalClick::StorageColumnSchema.parse("Tuple(JSON, Variant(String, UInt8))"),
    ]
    admitted.each do |schema|
      CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(schema).should be_true
    end

    variant = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Variant(String, UInt8)",
    ).not_nil!
    CrystalClick::BinaryPrefixFreeStaticTypeAdmission.admitted?(variant).should be_false

    dynamic_array = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(1))
    opaque_dynamic = CrystalClick::StorageColumnSchema.bulk(dynamic_array, dynamic_array.name)
    rejected_dynamic_product = CrystalClick::StorageColumnSchema.tuple(
      "Tuple(JSON, #{dynamic_array.name})",
      false,
      [] of String,
      [] of String,
      [object, opaque_dynamic] of CrystalClick::StorageColumnSchema,
    )
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(rejected_dynamic_product).should be_false

    [
      "Array(Dynamic(JSON))",
      "Array(Variant(JSON, UInt8))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::StorageColumnSchema.parse(declaration)
      end
    end
  end

  it "notifies before charging a fresh recursive read and remains reusable after observer refusal" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      codec_budget = CrystalClick::BinaryCodecBudget.new(limits)
      schema = CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.tagged_type.name)
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        "tagged",
        schema,
        limits,
        codec_budget: codec_budget,
      )
      before = {
        codec_budget.node_count,
        codec_budget.element_count,
        codec_budget.wire_byte_count,
      }

      observer_calls = 0
      refusing_observer = ->(_workspace_bytes : UInt64) do
        observer_calls += 1
        raise CrystalClick::BoundsError.new("test observer refuses fresh recursive source capture")
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_marks(0, reader.mark_count, refusing_observer)
      end
      observer_calls.should eq(1)
      {
        codec_budget.node_count,
        codec_budget.element_count,
        codec_budget.wire_byte_count,
      }.should eq(before)

      accepting_calls = 0
      accepting_observer = ->(_workspace_bytes : UInt64) do
        accepting_calls += 1
        nil
      end
      values = reader.read_marks(0, reader.mark_count, accepting_observer)
      actual = values.flat_map { |mark| mark }.map do |value|
        CompactJsonRecursivePublicW263Fixture.recursive_signature(schema, value)
      end
      accepting_calls.should be > 0
      actual.should eq(expected["tagged"])
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves caller JSON/Binary column order across MRK3 and MRK4" do
    labels = [
      "obj_v3_dyn_v3_advanced_mrk3_s0_variant_basic",
      "obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_compact",
    ]
    selected = ["pair", "pk", "tagged", "docs", "root"]

    labels.each do |label|
      parent, part_path, source_path, inventory = fixture.authenticated_copy(label)
      begin
        CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)

        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], selected)
        compact.columns.should eq(selected)
        compact_actual = CompactJsonRecursivePublicW263Fixture.scan_signatures(compact, selected)
        compact_actual.should eq(expected.select { |column, _| selected.includes?(column) })

        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], selected)
        typed.columns.should eq(selected)
        typed_actual = CompactJsonRecursivePublicW263Fixture.scan_signatures(typed, selected)
        typed_actual.should eq(expected.select { |column, _| selected.includes?(column) })
      ensure
        fixture.assert_original_unchanged!(source_path, inventory)
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "treats an equal-total Array size redistribution as valid changed parent association" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
    )
    begin
      fixture.rewrite_docs_last_mark_sizes!(
        part_path,
        {4_u64, 1_u64},
        CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
      )
      expected_docs = fixture.redistributed_docs_signatures
      expected_docs.should_not eq(expected["docs"])
      expected_docs.size.should eq(CompactJsonW263Fixture::ROWS)

      compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "docs"])
      compact_actual = CompactJsonRecursivePublicW263Fixture.scan_signatures(compact, ["pk", "docs"])
      compact_actual.should eq({
        "pk"   => expected["pk"],
        "docs" => expected_docs,
      })

      typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "docs"])
      typed_actual = CompactJsonRecursivePublicW263Fixture.scan_signatures(typed, ["pk", "docs"])
      typed_actual.should eq({
        "pk"   => expected["pk"],
        "docs" => expected_docs,
      })
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a true Array child-count mismatch before EOF or empty-candidate callbacks" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
    )
    begin
      fixture.rewrite_docs_last_mark_sizes!(
        part_path,
        {1_u64, 5_u64},
        CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
      )
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a

      compact_control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(compact_control).should eq(expected_keys)
      typed_control = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(typed_control).should eq(expected_keys)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "docs"])
        compact.scan_typed_window(CompactJsonW263Fixture::ROWS.to_u64, max_rows: 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)

      expect_raises(CrystalClick::CorruptPartError) do
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "docs"])
        compact.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)

      expect_raises(CrystalClick::CorruptPartError) do
        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "docs"])
        typed.scan_typed_window(CompactJsonW263Fixture::ROWS.to_u64, max_rows: 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)

      expect_raises(CrystalClick::CorruptPartError) do
        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "docs"])
        typed.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps recursive offline values under one cumulative Tuple-cell bound" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      copied = CompactJsonRecursivePublicW263Fixture.prepare_offline_catalog(
        part_path,
        File.join(parent, "offline-work"),
      )
      CompactJsonW263Fixture.assert_native_inventory!(copied[:part], inventory)
      catalog = CrystalClick::OfflineCatalog.open(copied[:root])
      table = catalog["lab"]["events"]
      table["pk"].values(max_rows: 8_u64).map(&.as(UInt64)).should eq(
        (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      )

      pair_table = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pair"])
      pair_table.part_mark_row_counts.should eq([CompactJsonW263Fixture::MARK_ROWS])
      mark_rows = pair_table.part_mark_row_counts[0]
      mark_indices = [] of Int32
      mark_rows.size.times { |mark_index| mark_indices << mark_index.to_i32 }
      pair_values_by_mark = [] of Array(CrystalClick::StorageColumnValue)
      per_mark_tuple_cells = [] of UInt64
      observed_pair_signatures = [] of String
      aggregate_budget = CrystalClick::ObjectValuesMaterializationBudget.new(
        max_tuple_cells: UInt64::MAX,
      )
      aggregate_budget.reserve_binary_values_base(CompactJsonW263Fixture::ROWS.to_u64)

      pair_table.scan_typed_candidate_marks([mark_indices]) do |batch|
        batch.mark_index.should eq(pair_values_by_mark.size)
        values = batch.recursive_values_for("pair").to_a
        values.size.to_u64.should eq(mark_rows[batch.mark_index])
        observed_pair_signatures.concat(
          CompactJsonRecursivePublicW263Fixture.batch_column_signatures(batch, "pair")
        )

        mark_budget = CrystalClick::ObjectValuesMaterializationBudget.new(
          max_tuple_cells: UInt64::MAX,
        )
        mark_budget.reserve_binary_values_base(values.size.to_u64)
        mark_budget.charge_storage_values(values)
        tuple_cells = mark_budget.tuple_cells
        per_mark_tuple_cells << tuple_cells

        before_aggregate_charge = aggregate_budget.tuple_cells
        aggregate_budget.charge_storage_values(values)
        (aggregate_budget.tuple_cells - before_aggregate_charge).should eq(tuple_cells)
        pair_values_by_mark << values
      end

      observed_pair_signatures.should eq(expected["pair"])
      per_mark_tuple_cells.size.should eq(mark_rows.size)
      cumulative_tuple_cells = 0_u64
      per_mark_tuple_cells.each do |tuple_cells|
        raise "pair Tuple-cell count overflows UInt64" if tuple_cells > UInt64::MAX - cumulative_tuple_cells
        cumulative_tuple_cells += tuple_cells
      end
      aggregate_budget.tuple_cells.should eq(cumulative_tuple_cells)
      cumulative_tuple_cells.should be > 0_u64
      per_mark_tuple_cells.each do |tuple_cells|
        tuple_cells.should be < cumulative_tuple_cells
      end
      per_mark_cap = cumulative_tuple_cells - 1_u64
      per_mark_cap.should be <= CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS
      per_mark_tuple_cells.each do |tuple_cells|
        tuple_cells.should be <= per_mark_cap
      end

      pair_values_by_mark.each_with_index do |values, mark_index|
        mark_control = CrystalClick::ObjectValuesMaterializationBudget.new(
          max_tuple_cells: per_mark_cap,
        )
        mark_control.reserve_binary_values_base(values.size.to_u64)
        mark_control.charge_storage_values(values)
        mark_control.tuple_cells.should eq(per_mark_tuple_cells[mark_index])
      end

      expect_raises(CrystalClick::BoundsError) do
        table["pair"].values(max_rows: 8_u64, max_tuple_cells: per_mark_cap)
      end

      # The independent fixture has eight rows and a two-cell Tuple per row,
      # so 15 is below the 16 Tuple cells present in the full result. This is
      # only a structural lower-bound refusal: ObjectDocument overhead may
      # also make an individual mark exceed 15, so this does not distinguish
      # a reset-per-mark budget.
      expect_raises(CrystalClick::BoundsError) do
        table["pair"].values(max_rows: 8_u64, max_tuple_cells: 15_u64)
      end

      expect_raises(CrystalClick::BoundsError) do
        table["pair"].values(max_rows: 7_u64)
      end
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a true Array child-count mismatch through offline values" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
    )
    begin
      fixture.rewrite_docs_last_mark_sizes!(
        part_path,
        {1_u64, 5_u64},
        CompactJsonRecursivePublicW263MutantFixture::ARRAY_MAP_MRK3_LABEL,
      )
      copied = CompactJsonRecursivePublicW263Fixture.prepare_offline_catalog(
        part_path,
        File.join(parent, "offline-work"),
      )
      catalog = CrystalClick::OfflineCatalog.open(copied[:root])
      table = catalog["lab"]["events"]
      table["pk"].values(max_rows: CompactJsonW263Fixture::ROWS.to_u64).map(&.as(UInt64)).should eq(
        (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      )

      # The copy retains a valid checksummed MRK3 whole-column envelope, but
      # its final Array(JSON) parent sizes claim one child more than the
      # native child-site grid contains.
      expect_raises(CrystalClick::CorruptPartError) do
        table["docs"].values(max_rows: CompactJsonW263Fixture::ROWS.to_u64)
      end
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights a reordered nested callback in Compact empty selection before any result" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.swap_site_callbacks!(part_path, "docs", "object_structure", "id")
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(control).should eq(expected_keys)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "docs"])
        compact.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Tuple sibling JSON sites distinct when a left-site callback is reordered" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.swap_column_callbacks!(
        part_path,
        "pair",
        "pair%2Eleft.object_structure",
        "pair%2Eleft.id",
      )
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      control = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(control).should eq(expected_keys)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "pair"])
        typed.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "validates the Tuple(JSON, UInt8) Array element site before empty selection" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.swap_column_callbacks!(
        part_path,
        "tagged",
        "tagged%2Edoc.object_structure",
        "tagged%2Edoc.id",
      )
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(control).should eq(expected_keys)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "tagged"])
        compact.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a JSON callback moved under a different selected parent column before callbacks" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.swap_callbacks_across_columns!(
        part_path,
        "docs",
        "docs.object_structure",
        "tagged",
        "tagged%2Edoc.object_structure",
      )
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
      compact_control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(compact_control).should eq(expected_keys)
      typed_control = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk"])
      CompactJsonRecursivePublicW263Fixture.primary_keys(typed_control).should eq(expected_keys)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk", "docs", "tagged"])
        compact.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)

      expect_raises(CrystalClick::CorruptPartError) do
        typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "docs", "tagged"])
        typed.scan_typed_candidate_marks([[] of Int32]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "binds recursive extents to actual physical-shard bytes, not matching metadata" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.assert_recursive_extent_provenance!(part_path)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "binds a recursive parent granule to selected column, mark, row grid, offset and bytes" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.assert_parent_granule_provenance!(part_path)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "resolves recursive Compact pairs only through their authenticated callback extents" do
    fixture.assert_recursive_coordinate_pair_resolution!
  end

  it "requires one completed parent lifecycle and its exact budget before prepared-source admission" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.assert_prepared_source_gate!(part_path)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a late second Compact candidate's reordered nested callback before the first callback" do
    parent, first, second, source_path, _label, inventory = fixture.authenticated_candidate_pair(
      CompactJsonRecursivePublicW263MutantFixture::ARRAY_LABEL,
    )
    begin
      fixture.swap_site_callbacks!(second, "docs", "object_structure", "id")
      expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a

      {first, second}.each do |part_path|
        control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
        CompactJsonRecursivePublicW263Fixture.primary_keys(control).should eq(expected_keys)

        typed_control = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk"])
        CompactJsonRecursivePublicW263Fixture.primary_keys(typed_control).should eq(expected_keys)
      end

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        typed = CrystalClick::TypedPartTable.open_selected_typed([first, second], ["pk", "docs"])
        typed.scan_typed do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end

  it "binds explicit root JSON reads to the exact read-direction codec budget" do
    parent, part_path, source_path, inventory = fixture.authenticated_copy(
      CompactJsonW263Fixture::NATIVE_LABEL,
    )
    begin
      CompactJsonW263Fixture.assert_native_inventory!(part_path, inventory)
      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      explicit_budget = CrystalClick::BinaryCodecBudget.new(limits)
      explicit_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        CompactJsonW263Fixture.json_type,
        limits,
        codec_budget: explicit_budget,
      )

      observer_calls = 0
      observer = ->(_workspace_bytes : UInt64) do
        observer_calls += 1
        nil
      end

      before_exact_observer = observer_calls
      explicit_result = explicit_reader.read_marks_with_budget(
        explicit_reader.mark_count,
        0,
        explicit_budget,
        observer,
      )
      explicit_result.should be_empty
      observer_calls.should be > before_exact_observer

      same_limits_foreign_budget = CrystalClick::BinaryCodecBudget.new(limits)
      before_explicit = {
        explicit_budget.node_count,
        explicit_budget.element_count,
        explicit_budget.wire_byte_count,
      }
      before_foreign = {
        same_limits_foreign_budget.node_count,
        same_limits_foreign_budget.element_count,
        same_limits_foreign_budget.wire_byte_count,
      }
      before_observer = observer_calls
      expect_raises(ArgumentError) do
        explicit_reader.read_marks_with_budget(
          explicit_reader.mark_count,
          0,
          same_limits_foreign_budget,
          observer,
        )
      end
      {
        explicit_budget.node_count,
        explicit_budget.element_count,
        explicit_budget.wire_byte_count,
      }.should eq(before_explicit)
      {
        same_limits_foreign_budget.node_count,
        same_limits_foreign_budget.element_count,
        same_limits_foreign_budget.wire_byte_count,
      }.should eq(before_foreign)
      observer_calls.should eq(before_observer)

      unbudgeted_reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        "root",
        CompactJsonW263Fixture.json_type,
        limits,
      )
      writing_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
      before_writing = {
        writing_budget.node_count,
        writing_budget.element_count,
        writing_budget.wire_byte_count,
      }
      before_observer = observer_calls
      expect_raises(ArgumentError) do
        unbudgeted_reader.read_marks_with_budget(
          unbudgeted_reader.mark_count,
          0,
          writing_budget,
          observer,
        )
      end
      {
        writing_budget.node_count,
        writing_budget.element_count,
        writing_budget.wire_byte_count,
      }.should eq(before_writing)
      observer_calls.should eq(before_observer)

      mismatched_limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: limits.max_depth,
        max_nodes: limits.max_nodes,
        max_elements: limits.max_elements,
        max_bytes: limits.max_bytes - 1,
      )
      mismatched_budget = CrystalClick::BinaryCodecBudget.new(mismatched_limits)
      before_mismatched = {
        mismatched_budget.node_count,
        mismatched_budget.element_count,
        mismatched_budget.wire_byte_count,
      }
      before_observer = observer_calls
      expect_raises(ArgumentError) do
        unbudgeted_reader.read_marks_with_budget(
          unbudgeted_reader.mark_count,
          0,
          mismatched_budget,
          observer,
        )
      end
      {
        mismatched_budget.node_count,
        mismatched_budget.element_count,
        mismatched_budget.wire_byte_count,
      }.should eq(before_mismatched)
      observer_calls.should eq(before_observer)

      external_budget = CrystalClick::BinaryCodecBudget.new(limits)
      external_result = unbudgeted_reader.read_marks_with_budget(
        unbudgeted_reader.mark_count,
        0,
        external_budget,
        observer,
      )
      external_result.should be_empty
      external_budget.node_count.should be > 0_i64
      observer_calls.should be > before_observer
    ensure
      fixture.assert_original_unchanged!(source_path, inventory)
      FileUtils.rm_rf(parent)
    end
  end
end
