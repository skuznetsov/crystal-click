#!/usr/bin/env python3
"""Install isolated Compact JSON filter-stage timing hooks."""

from pathlib import Path


def install(root: Path) -> None:
    """Install bounded Compact JSON filter-stage hooks in a disposable copy."""
    sources: dict[Path, str] = {}

    def replace_once(relative_path: str, old: str, new: str) -> None:
        path = root / relative_path
        source = sources[path] if path in sources else path.read_text()
        if new.strip() in source:
            return
        count = source.count(old)
        if count != 1:
            raise RuntimeError(f"{path}: expected one stage hook site, found {count}")
        sources[path] = source.replace(old, new, 1)

    # The coordinator performs one shared UInt64 predicate and hit-index pass.
    replace_once(
        "src/crystal_click/compact_static_json_bulk_column_reader.cr",
        "      selected_mark_rows = 0_u64\n"
        "      current_offset = 0_u64\n"
        "      @mark_count.times do |mark|\n",
        "      selected_mark_rows = 0_u64\n"
        "      current_offset = 0_u64\n"
        "      diagnostic_mask_started = Time.instant\n"
        "      diagnostic_mask_examined_rows = 0_u64\n"
        "      diagnostic_mask_key_bytes = 0_u64\n"
        "      @mark_count.times do |mark|\n",
    )
    replace_once(
        "src/crystal_click/compact_static_json_bulk_column_reader.cr",
        "        key_bytes = filter_capture.root_mark_shard_bytes_at(mark, 0)\n"
        "        expected_bytes = checked_multiply(rows, sizeof(UInt64).to_u64)\n",
        "        key_bytes = filter_capture.root_mark_shard_bytes_at(mark, 0)\n"
        "        diagnostic_mask_key_bytes += key_bytes.size.to_u64\n"
        "        expected_bytes = checked_multiply(rows, sizeof(UInt64).to_u64)\n",
    )
    replace_once(
        "src/crystal_click/compact_static_json_bulk_column_reader.cr",
        "        matching_rows = [] of Int32\n"
        "        rows.to_i.times do |row|\n"
        "          value = IO::ByteFormat::LittleEndian.decode(\n",
        "        matching_rows = [] of Int32\n"
        "        rows.to_i.times do |row|\n"
        "          diagnostic_mask_examined_rows += 1_u64\n"
        "          value = IO::ByteFormat::LittleEndian.decode(\n",
    )
    replace_once(
        "src/crystal_click/compact_static_json_bulk_column_reader.cr",
        "      unless current_offset == @row_count\n"
        "        raise CorruptPartError.new(\"Compact filtered JSON key grid differs from the part row count\")\n"
        "      end\n\n      key_frames = filter_capture.authenticated_frames\n",
        "      unless current_offset == @row_count\n"
        "        raise CorruptPartError.new(\"Compact filtered JSON key grid differs from the part row count\")\n"
        "      end\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"mask_construction\", (Time.instant - diagnostic_mask_started).total_nanoseconds.to_u64,\n"
        "        diagnostic_mask_examined_rows, diagnostic_mask_key_bytes,\n"
        "        {\"examined_rows\" => diagnostic_mask_examined_rows,\n"
        "         \"kept_rows\" => selected_rows, \"marks\" => mark_indices.size.to_u64},\n"
        "      )\n\n      key_frames = filter_capture.authenticated_frames\n",
    )

    # This map turns source-row ordinals into dense destination-row ordinals.
    # Time allocation, initialization, and scatter as one explicit mark-local
    # row-map build; the source mask itself is measured above.
    replace_once(
        "src/crystal_click/compact_json_columnar_batch.cr",
        "      reset!\n"
        "      required_map_size = source_rows.to_i\n",
        "      diagnostic_packed_map_started = Time.instant\n"
        "      reset!\n"
        "      required_map_size = source_rows.to_i\n",
    )
    replace_once(
        "src/crystal_click/compact_json_columnar_batch.cr",
        "      selected_rows.each_with_index do |row, destination_row|\n"
        "        @selected_output_rows[row] = destination_row.to_i32\n"
        "      end\n"
        "      @cell_count = 0_u64\n",
        "      selected_rows.each_with_index do |row, destination_row|\n"
        "        @selected_output_rows[row] = destination_row.to_i32\n"
        "      end\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"packed_row_map_build\",\n"
        "        (Time.instant - diagnostic_packed_map_started).total_nanoseconds.to_u64,\n"
        "        source_rows, source_rows.to_u64 * sizeof(Int32).to_u64,\n"
        "        {\"selected_rows\" => selected_rows.size.to_u64},\n"
        "      )\n"
        "      @cell_count = 0_u64\n",
    )
    replace_once(
        "src/crystal_click/compact_json_columnar_batch.cr",
        "      column.complete_nullable_uint32_fill!(rows)\n"
        "      compact_selected_nullable_uint32!(column) if @selected_source_rows_active\n",
        "      column.complete_nullable_uint32_fill!(rows)\n"
        "      if @selected_source_rows_active\n"
        "        diagnostic_nullable_pack_started = Time.instant\n"
        "        compact_selected_nullable_uint32!(column)\n"
        "        CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "          \"nullable_pack\", (Time.instant - diagnostic_nullable_pack_started).total_nanoseconds.to_u64,\n"
        "          @selected_source_row_count.to_u64, 0_u64, {\"rows\" => @selected_source_row_count.to_u64},\n"
        "        )\n"
        "      end\n",
    )

    # Compact Advanced plan materialization has disjoint setup, companion
    # column fill, finish, and final workspace validation spans.
    replace_once(
        "src/crystal_click/compact_static_json_advanced_part_plan.cr",
        "      @advanced_marks[ordinal].decode_columnar_with_budget(budget, output)\n"
        "      @companion_columns.each do |name|\n",
        "      @advanced_marks[ordinal].decode_columnar_with_budget(budget, output)\n"
        "      diagnostic_companion_fill_started = Time.instant\n"
        "      @companion_columns.each do |name|\n",
    )
    replace_once(
        "src/crystal_click/compact_static_json_advanced_part_plan.cr",
        "        output.fill_uint64_column!(name, bytes, rows)\n"
        "      end\n"
        "      output.finish_selected_mark! if matching_rows\n"
        "      output.validate_workspace!\n",
        "        output.fill_uint64_column!(name, bytes, rows)\n"
        "      end\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"batch_companion_fill\",\n"
        "        (Time.instant - diagnostic_companion_fill_started).total_nanoseconds.to_u64,\n"
        "        rows, 0_u64, {\"columns\" => @companion_columns.size.to_u64},\n"
        "      )\n"
        "      if matching_rows\n"
        "        diagnostic_batch_finish_started = Time.instant\n"
        "        output.finish_selected_mark!\n"
        "        CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "          \"batch_finish\", (Time.instant - diagnostic_batch_finish_started).total_nanoseconds.to_u64,\n"
        "          output.row_count.to_u64, 0_u64, {\"mark_calls\" => 1_u64},\n"
        "        )\n"
        "      end\n"
        "      diagnostic_batch_validate_started = Time.instant\n"
        "      output.validate_workspace!\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"batch_validate\", (Time.instant - diagnostic_batch_validate_started).total_nanoseconds.to_u64,\n"
        "        output.row_count.to_u64, 0_u64, {\"mark_calls\" => 1_u64},\n"
        "      )\n",
    )

    # Split Copy index accounting into dictionary metadata, index/body scan,
    # owned dictionary materialization, and the selected value-envelope walk.
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "      budget.charge_wire_bytes(lane_bytes)\n"
        "      dictionary = ObjectSharedCopyDictionary.new(bucket_structures, budget)\n",
        "      budget.charge_wire_bytes(lane_bytes)\n"
        "      diagnostic_dictionary_metadata_started = Time.instant\n"
        "      dictionary = ObjectSharedCopyDictionary.new(bucket_structures, budget)\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_dictionary_metadata\",\n"
        "        (Time.instant - diagnostic_dictionary_metadata_started).total_nanoseconds.to_u64,\n"
        "        dictionary.row_count.to_u64, lane_bytes, {\"paths\" => dictionary.path_count.to_u64},\n"
        "      )\n",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "    ) : UInt64\n"
        "      referenced_bytes = 0_u64\n"
        "      index_offset = 0\n"
        "      row_index = 0\n",
        "    ) : UInt64\n"
        "      diagnostic_index_scan_started = Time.instant\n"
        "      referenced_bytes = 0_u64\n"
        "      index_offset = 0\n"
        "      row_index = 0\n",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "        row_index += 1\n"
        "      end\n"
        "      referenced_bytes\n"
        "    end\n\n    private def self.write_counts_and_indexes(",
        "        row_index += 1\n"
        "      end\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_index_scan\",\n"
        "        (Time.instant - diagnostic_index_scan_started).total_nanoseconds.to_u64,\n"
        "        (sizes.size // 8).to_u64, indexes.size.to_u64,\n"
        "        {\"entries\" => (index_offset // width).to_u64,\n"
        "         \"referenced_path_bytes\" => referenced_bytes},\n"
        "      )\n"
        "      referenced_bytes\n"
        "    end\n\n    private def self.write_counts_and_indexes(",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_dictionary.cr",
        "      return nil if @materialized\n"
        "      if referenced_path_bytes > UInt64::MAX - @metadata_path_bytes\n",
        "      return nil if @materialized\n"
        "      diagnostic_dictionary_materialize_started = Time.instant\n"
        "      if referenced_path_bytes > UInt64::MAX - @metadata_path_bytes\n",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_dictionary.cr",
        "      @materialized = true\n"
        "      nil\n"
        "    end\n\n    def index_width : Int32\n",
        "      @materialized = true\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_dictionary_materialization\",\n"
        "        (Time.instant - diagnostic_dictionary_materialize_started).total_nanoseconds.to_u64,\n"
        "        @row_count.to_u64, 0_u64, {\"paths\" => @path_count.to_u64},\n"
        "      )\n"
        "      nil\n"
        "    end\n\n    def index_width : Int32\n",
    )

    # The masked route fills a compact per-path row-reference ledger from the
    # Copy values lane. Its varuint/frame parsing remains part of this gross
    # fill span and is named explicitly in the report.
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "      dictionary.materialize!(budget, referenced_path_bytes)\n\n"
        "      values_context = BinaryCodecContext.new(budget.limits, values, false, budget, false)\n"
        "      index_offset = 0\n"
        "      row_index = 0\n"
        "      while row_index < row_count\n"
        "        entry_count = read_u64_le(sizes, row_index * 8).to_i\n"
        "        entry_index = 0\n"
        "        while entry_index < entry_count\n"
        "          dictionary_index = read_index(indexes, index_offset, width).to_i\n"
        "          index_offset += width\n"
        "\n          envelope_size = values_context.read_var_uint\n",
        "      dictionary.materialize!(budget, referenced_path_bytes)\n\n"
        "      diagnostic_copy_row_map_fill_started = Time.instant\n"
        "      values_context = BinaryCodecContext.new(budget.limits, values, false, budget, false)\n"
        "      index_offset = 0\n"
        "      row_index = 0\n"
        "      while row_index < row_count\n"
        "        entry_count = read_u64_le(sizes, row_index * 8).to_i\n"
        "        entry_index = 0\n"
        "        while entry_index < entry_count\n"
        "          dictionary_index = read_index(indexes, index_offset, width).to_i\n"
        "          index_offset += width\n"
        "\n          envelope_size = values_context.read_var_uint\n",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "      values_context.ensure_consumed\n"
        "      output.finish_selected_copy_reference_fill!\n"
        "      nil\n"
        "    end\n\n    # :nodoc:\n    # Reuse the exact column decoder on one already-framed borrowed span.",
        "      values_context.ensure_consumed\n"
        "      output.finish_selected_copy_reference_fill!\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_row_map_fill\",\n"
        "        (Time.instant - diagnostic_copy_row_map_fill_started).total_nanoseconds.to_u64,\n"
        "        row_count.to_u64, values.size.to_u64,\n"
        "        {\"entries\" => total_entries, \"value_envelopes\" => total_entries},\n"
        "      )\n"
        "      nil\n"
        "    end\n\n    # :nodoc:\n    # Reuse the exact column decoder on one already-framed borrowed span.",
    )

    # Sample one append out of every 32 within each mark. The sample phase is
    # rotated by mark index; only sampled calls read the clock and all timing
    # is accumulated locally before one thread-safe counter update.
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "      values_context = BinaryCodecContext.new(budget.limits, values, false, budget, false)\n"
        "      index_offset = 0\n"
        "      row_index = 0\n"
        "      while row_index < row_count\n"
        "        entry_count = read_u64_le(sizes, row_index * 8).to_i\n"
        "        entry_index = 0\n"
        "        while entry_index < entry_count\n"
        "          dictionary_index = read_index(indexes, index_offset, width).to_i\n"
        "          index_offset += width\n\n          value = read_dynamic_column_value(values_context, budget, borrow_string_slices)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          output.append_column_cell!(column, row_offset + row_index, value, binding_workspace_bytes)\n",
        "      diagnostic_old_copy_value_started = Time.instant\n"
        "      diagnostic_append_seen = 0_u64\n"
        "      diagnostic_append_sampled = 0_u64\n"
        "      diagnostic_append_sampled_ns = 0_u64\n"
        "      values_context = BinaryCodecContext.new(budget.limits, values, false, budget, false)\n"
        "      index_offset = 0\n"
        "      row_index = 0\n"
        "      while row_index < row_count\n"
        "        entry_count = read_u64_le(sizes, row_index * 8).to_i\n"
        "        entry_index = 0\n"
        "        while entry_index < entry_count\n"
        "          dictionary_index = read_index(indexes, index_offset, width).to_i\n"
        "          index_offset += width\n\n          value = read_dynamic_column_value(values_context, budget, borrow_string_slices)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          diagnostic_append_seen += 1_u64\n"
        "          if (diagnostic_append_seen + output.mark_index.to_u64) % 32_u64 == 0_u64\n"
        "            diagnostic_append_started = Time.instant\n"
        "            output.append_column_cell!(column, row_offset + row_index, value, binding_workspace_bytes)\n"
        "            diagnostic_append_sampled_ns += (Time.instant - diagnostic_append_started).total_nanoseconds.to_u64\n"
        "            diagnostic_append_sampled += 1_u64\n"
        "          else\n"
        "            output.append_column_cell!(column, row_offset + row_index, value, binding_workspace_bytes)\n"
        "          end\n",
    )
    replace_once(
        "src/crystal_click/object_shared_copy_codec.cr",
        "      values_context.ensure_consumed\n"
        "      row_count.to_u64\n"
        "    end\n\n    private def self.read_dynamic_column_value(",
        "      values_context.ensure_consumed\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"old_copy_row_decode_and_append\",\n"
        "        (Time.instant - diagnostic_old_copy_value_started).total_nanoseconds.to_u64,\n"
        "        row_count.to_u64, values.size.to_u64, {\"entries\" => total_entries},\n"
        "      )\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_batch_append_sampled\", diagnostic_append_sampled_ns,\n"
        "        diagnostic_append_sampled, 0_u64,\n"
        "        {\"observed_calls\" => diagnostic_append_seen,\n"
        "         \"sampled_calls\" => diagnostic_append_sampled,\n"
        "         \"estimated_elapsed_ns\" => diagnostic_append_sampled == 0_u64 ? 0_u64 :\n"
        "           diagnostic_append_sampled_ns * diagnostic_append_seen // diagnostic_append_sampled},\n"
        "        calls: diagnostic_append_sampled,\n"
        "      )\n"
        "      row_count.to_u64\n"
        "    end\n\n    private def self.read_dynamic_column_value(",
    )

    # SharedData parse and strict Copy/Data reconciliation stay separate in
    # the report. The outer masked span includes required selected-cell
    # appends; the parse split is nested within it and is never added twice.
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "      dictionary_index = 0\n"
        "      bucket_chunks.each do |bucket|\n"
        "        bucket.path_count.times do |path_index|\n"
        "          path = bucket.path_at(path_index)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          references = output.selected_copy_references_for_path(dictionary_index.to_i32)\n",
        "      diagnostic_copy_data_verify_started = Time.instant\n"
        "      diagnostic_copy_data_parse_ns = 0_u64\n"
        "      diagnostic_copy_data_paths = 0_u64\n"
        "      diagnostic_copy_data_bytes = 0_u64\n"
        "      diagnostic_append_seen = 0_u64\n"
        "      diagnostic_append_sampled = 0_u64\n"
        "      diagnostic_append_sampled_ns = 0_u64\n"
        "      dictionary_index = 0\n"
        "      bucket_chunks.each do |bucket|\n"
        "        bucket.path_count.times do |path_index|\n"
        "          path = bucket.path_at(path_index)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          references = output.selected_copy_references_for_path(dictionary_index.to_i32)\n",
    )
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n\n"
        "          reference_index = 0\n",
        "          diagnostic_data_parse_started = Time.instant\n"
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n"
        "          diagnostic_copy_data_parse_ns += (Time.instant - diagnostic_data_parse_started).total_nanoseconds.to_u64\n"
        "          diagnostic_copy_data_paths += 1_u64\n"
        "          diagnostic_copy_data_bytes += path.streams.data_size.to_u64\n\n"
        "          reference_index = 0\n",
    )
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "              output.append_column_cell!(column, row_offset + row_index, cell, compare_workspace_bytes)\n"
        "              reference_index += 1\n",
        "              diagnostic_append_seen += 1_u64\n"
        "              if (diagnostic_append_seen + output.mark_index.to_u64) % 32_u64 == 0_u64\n"
        "                diagnostic_append_started = Time.instant\n"
        "                output.append_column_cell!(column, row_offset + row_index, cell, compare_workspace_bytes)\n"
        "                diagnostic_append_sampled_ns += (Time.instant - diagnostic_append_started).total_nanoseconds.to_u64\n"
        "                diagnostic_append_sampled += 1_u64\n"
        "              else\n"
        "                output.append_column_cell!(column, row_offset + row_index, cell, compare_workspace_bytes)\n"
        "              end\n"
        "              reference_index += 1\n",
    )
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "      unless dictionary_index == columns_by_index.size\n"
        "        raise CorruptPartError.new(\"Object shared path count disagrees with its Copy column bindings\")\n"
        "      end\n"
        "      nil\n"
        "    end\n\n    private def self.copy_value_matches_dynamic?(",
        "      unless dictionary_index == columns_by_index.size\n"
        "        raise CorruptPartError.new(\"Object shared path count disagrees with its Copy column bindings\")\n"
        "      end\n"
        "      diagnostic_copy_data_elapsed = (Time.instant - diagnostic_copy_data_verify_started).total_nanoseconds.to_u64\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_data_parse\", diagnostic_copy_data_parse_ns, row_count.to_u64, diagnostic_copy_data_bytes,\n"
        "        {\"paths\" => diagnostic_copy_data_paths, \"nested_in\" => 1_u64},\n"
        "        calls: diagnostic_copy_data_paths,\n"
        "      )\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_data_verify_and_append\", diagnostic_copy_data_elapsed, row_count.to_u64,\n"
        "        diagnostic_copy_data_bytes, {\"paths\" => diagnostic_copy_data_paths},\n"
        "      )\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"copy_batch_append_sampled\", diagnostic_append_sampled_ns,\n"
        "        diagnostic_append_sampled, 0_u64,\n"
        "        {\"observed_calls\" => diagnostic_append_seen,\n"
        "         \"sampled_calls\" => diagnostic_append_sampled,\n"
        "         \"estimated_elapsed_ns\" => diagnostic_append_sampled == 0_u64 ? 0_u64 :\n"
        "           diagnostic_append_sampled_ns * diagnostic_append_seen // diagnostic_append_sampled},\n"
        "        calls: diagnostic_append_sampled,\n"
        "      )\n"
        "      nil\n"
        "    end\n\n    private def self.copy_value_matches_dynamic?(",
    )

    # The old row-major route decodes the complete Copy value lane into cells,
    # then fully validates it against each SharedData path. Keep those spans
    # separately from the selected-reference ledger route.
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "      dictionary_index = 0\n"
        "      bucket_chunks.each do |bucket|\n"
        "        bucket.path_count.times do |path_index|\n"
        "          path = bucket.path_at(path_index)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          output.validate_workspace!(compare_workspace_bytes)\n"
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n",
        "      diagnostic_old_data_verify_started = Time.instant\n"
        "      diagnostic_old_data_parse_ns = 0_u64\n"
        "      diagnostic_old_data_paths = 0_u64\n"
        "      diagnostic_old_data_bytes = 0_u64\n"
        "      dictionary_index = 0\n"
        "      bucket_chunks.each do |bucket|\n"
        "        bucket.path_count.times do |path_index|\n"
        "          path = bucket.path_at(path_index)\n"
        "          column = columns_by_index[dictionary_index]\n"
        "          output.validate_workspace!(compare_workspace_bytes)\n"
        "          diagnostic_old_data_parse_started = Time.instant\n"
        "          decoded = decode_path_for_column_verification(path, row_count, budget, profile, nested_context)\n"
        "          diagnostic_old_data_parse_ns += (Time.instant - diagnostic_old_data_parse_started).total_nanoseconds.to_u64\n"
        "          diagnostic_old_data_paths += 1_u64\n"
        "          diagnostic_old_data_bytes += path.streams.data_size.to_u64\n",
    )
    replace_once(
        "src/crystal_click/object_shared_advanced_chunk_codec.cr",
        "      unless dictionary_index == columns_by_index.size\n"
        "        raise CorruptPartError.new(\"Object shared path count disagrees with its Copy column bindings\")\n"
        "      end\n"
        "      nil\n"
        "    end\n\n    private def self.verify_selected_path_values_in_columns(",
        "      unless dictionary_index == columns_by_index.size\n"
        "        raise CorruptPartError.new(\"Object shared path count disagrees with its Copy column bindings\")\n"
        "      end\n"
        "      diagnostic_old_data_elapsed = (Time.instant - diagnostic_old_data_verify_started).total_nanoseconds.to_u64\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"old_data_parse\", diagnostic_old_data_parse_ns, row_count.to_u64, diagnostic_old_data_bytes,\n"
        "        {\"paths\" => diagnostic_old_data_paths, \"nested_in\" => 1_u64},\n"
        "        calls: diagnostic_old_data_paths,\n"
        "      )\n"
        "      CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "        \"old_data_verify\", diagnostic_old_data_elapsed, row_count.to_u64, diagnostic_old_data_bytes,\n"
        "        {\"paths\" => diagnostic_old_data_paths},\n"
        "      )\n"
        "      nil\n"
        "    end\n\n    private def self.verify_selected_path_values_in_columns(",
    )

    # Load the dedicated counter module only in the stage-diagnostic build.
    probe_path = root / "benchmarks" / "compact_json_filter_scan_probe.cr"
    probe = probe_path.read_text()
    if "compact_json_filter_stage_counters\"" not in probe:
        marker = 'require "../scripts/support/compact_physical_context_w259_fixture"\n'
        if probe.count(marker) != 1:
            raise RuntimeError(f"{probe_path}: expected one conditional require insertion site")
        require_line = (
            "{% if flag?(:compact_json_filter_stage_diagnostic) %}\n"
            "  require \"../scripts/support/compact_json_filter_stage_counters\"\n"
            "{% end %}\n"
        )
        probe = probe.replace(marker, marker + require_line, 1)

    run_scan_marker = (
        "    {% if flag?(:compact_json_scan_diagnostic) %}\n"
        "      CrystalClick::CompactJSONScanProbeCounters.reset!\n"
        "    {% end %}\n"
        "    gc_bytes_before = GC.stats.total_bytes\n"
    )
    run_scan_replacement = (
        "    {% if flag?(:compact_json_scan_diagnostic) %}\n"
        "      CrystalClick::CompactJSONScanProbeCounters.reset!\n"
        "    {% end %}\n"
        "    {% if flag?(:compact_json_filter_stage_diagnostic) %}\n"
        "      CrystalClick::CompactJSONFilterStageCounters.reset!\n"
        "    {% end %}\n"
        "    gc_bytes_before = GC.stats.total_bytes\n"
    )
    if probe.count(run_scan_marker) != 1:
        raise RuntimeError(f"{probe_path}: expected one per-scan stage reset site")
    probe = probe.replace(run_scan_marker, run_scan_replacement, 1)

    # Measure the whole production mark decode call as the worker contribution.
    mark_start = '              if job.route == "masked"\n                filtered = job.filtered_plan ||\n'
    mark_start_new = (
        "              {% if flag?(:compact_json_filter_stage_diagnostic) %}\n"
        "                diagnostic_mark_decode_started = Time.instant\n"
        "              {% end %}\n"
        "              if job.route == \"masked\"\n"
        "                filtered = job.filtered_plan ||\n"
    )
    if probe.count(mark_start) != 1:
        raise RuntimeError(f"{probe_path}: expected one worker mark-decode start site")
    probe = probe.replace(mark_start, mark_start_new, 1)
    mark_end = '              end\n              completed << CompletedMark.new(mark, batch)\n'
    mark_end_new = (
        "              end\n"
        "              {% if flag?(:compact_json_filter_stage_diagnostic) %}\n"
        "                CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "                  \"worker_mark_decode\",\n"
        "                  (Time.instant - diagnostic_mark_decode_started).total_nanoseconds.to_u64,\n"
        "                  batch.row_count.to_u64, 0_u64, {\"mark_calls\" => 1_u64},\n"
        "                )\n"
        "              {% end %}\n"
        "              completed << CompletedMark.new(mark, batch)\n"
    )
    if probe.count(mark_end) != 1:
        raise RuntimeError(f"{probe_path}: expected one worker mark-decode end site")
    probe = probe.replace(mark_end, mark_end_new, 1)

    # Batch setup and reset occur in the benchmark worker. Setup is first-use
    # only; reset/fill/finish timings are per mark and remain distinct.
    old = """              batch = output_arenas[arena_key]? || begin
                created = job.plan.new_columnar_output(job.output_limit)
                output_arenas[arena_key] = created
                created
              end
              batch.reset!
"""
    new = """              batch = output_arenas[arena_key]? || begin
                {% if flag?(:compact_json_filter_stage_diagnostic) %}
                  diagnostic_batch_setup_started = Time.instant
                {% end %}
                created = job.plan.new_columnar_output(job.output_limit)
                {% if flag?(:compact_json_filter_stage_diagnostic) %}
                  CrystalClick::CompactJSONFilterStageCounters.record!(
                    "batch_setup", (Time.instant - diagnostic_batch_setup_started).total_nanoseconds.to_u64,
                    created.row_count.to_u64, 0_u64, {"setup_calls" => 1_u64},
                  )
                {% end %}
                output_arenas[arena_key] = created
                created
              end
              {% if flag?(:compact_json_filter_stage_diagnostic) %}
                diagnostic_batch_reset_started = Time.instant
              {% end %}
              batch.reset!
              {% if flag?(:compact_json_filter_stage_diagnostic) %}
                CrystalClick::CompactJSONFilterStageCounters.record!(
                  "batch_reset", (Time.instant - diagnostic_batch_reset_started).total_nanoseconds.to_u64,
                  batch.row_count.to_u64, 0_u64, {"reset_calls" => 1_u64},
                )
              {% end %}
"""
    if old not in probe:
        raise RuntimeError(f"{probe_path}: expected one batch setup/reset insertion site")
    probe = probe.replace(old, new, 1)

    # Expose the counter only in the dedicated diagnostic build. Existing
    # --lz4-only and stock probe JSON remain byte-for-byte compatible.
    probe = probe.replace(
        "    diagnostics_json = JSON::Any.new(nil)\n",
        "    diagnostics_json = JSON::Any.new(nil)\n"
        "    filter_stage_json = JSON::Any.new(nil)\n"
        "    {% if flag?(:compact_json_filter_stage_diagnostic) %}\n"
        "      filter_stage_json = JSON::Any.new(\n"
        "        CrystalClick::CompactJSONFilterStageCounters.snapshot(worker_thread_ids),\n"
        "      )\n"
        "    {% end %}\n",
        1,
    )
    probe = probe.replace(
        '      "diagnostics"                    => diagnostics_json,\n',
        '      "diagnostics"                    => diagnostics_json,\n'
        '      "filter_stage_diagnostics"       => filter_stage_json,\n',
        1,
    )
    sources[probe_path] = probe

    # Ordinary typed and Dynamic arrays are appended to the reusable columnar
    # batch as one coarse span. This call is separate from nullable packing and
    # SharedData companion fill.
    doc_path = root / "src" / "crystal_click" / "object_document_codec.cr"
    doc = sources[doc_path] if doc_path in sources else doc_path.read_text()
    ordinary_call = "        append_ordinary_columns(target[:output], typed_rows, dynamic_rows, budget)\n"
    ordinary_timed = (
        "        diagnostic_ordinary_assembly_started = Time.instant\n"
        "        append_ordinary_columns(target[:output], typed_rows, dynamic_rows, budget)\n"
        "        CrystalClick::CompactJSONFilterStageCounters.record!(\n"
        "          \"ordinary_batch_assembly\",\n"
        "          (Time.instant - diagnostic_ordinary_assembly_started).total_nanoseconds.to_u64,\n"
        "          0_u64, 0_u64, {\"selected_mark_count\" => selected_count.to_u64},\n"
        "        )\n"
    )
    if ordinary_timed not in doc:
        if doc.count(ordinary_call) != 1:
            raise RuntimeError(f"{doc_path}: expected one ordinary column assembly hook site")
        doc = doc.replace(ordinary_call, ordinary_timed, 1)
    sources[doc_path] = doc

    for path, source in sources.items():
        path.write_text(source)
