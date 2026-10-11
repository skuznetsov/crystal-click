require "../src/crystal_click"
require "json"
require "./support/compact_json_w263_fixture"

module CheckCompactJSONW263
  FORMAT = "compact_json_w263_baseline_helper_v1"
  GREEN_FORMAT = "compact_json_w263_green_helper_v1"
  MANIFEST_FORMAT = "compact_json_w263_native_manifest_v1"
  REFUSAL = "selected Compact declaration is outside static or Dynamic BinaryBulk admission"
  JSON_COLUMNS = ["root", "docs", "tagged", "pair"]
  OFFLINE_WRAPPER_COLUMNS = ["docs", "tagged", "pair"]
  GREEN_COLUMNS = ["scalar", "text", "payload", "choice"] + JSON_COLUMNS
  OFFLINE_COLUMNS = ["scalar", "text", "payload", "choice"] + JSON_COLUMNS

  alias Scan = NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))
  alias Report = NamedTuple(
    mark_rows: Array(Array(UInt64)),
    full: Scan,
    first: Scan,
    middle: Scan,
    last: Scan,
    eof: Scan,
  )
  alias PersistedChunk = NamedTuple(
    row_count: UInt64,
    paths: Array(String),
    data_marks: Tuple(UInt64, UInt64),
    paths_marks: Tuple(UInt64, UInt64),
    paths_substreams_metadata_marks: Tuple(UInt64, UInt64),
  )
  alias PersistedBucket = NamedTuple(bucket: Int32, chunks: Array(PersistedChunk))
  alias PersistedArraySizeWitness = NamedTuple(
    wrapper_stream: String,
    source_mark_format: String,
    wrapper_callback_index: Int32,
    wrapper_callback_schedule: Array(String),
    parent_row_count: UInt64,
    logical_start: Int64,
    logical_end: Int64,
    occurrences_by_parent: Array(UInt64),
  )
  alias PersistedObjectSite = NamedTuple(
    column: String,
    owner: String,
    callback_order: Array(String),
    parent_occurrence_source: String,
    parent_row_occurrences: Array(UInt64),
    array_size_witness: PersistedArraySizeWitness?,
    wire_version: UInt64,
    shared_data_version: UInt64,
    bucket_count: UInt64,
    dynamic_paths: Array(String),
    buckets: Array(PersistedBucket),
  )
  alias PersistedGranule = NamedTuple(
    mark: Int32,
    row_offset: UInt64,
    row_count: UInt64,
    first_stream: String?,
    structure_prefix_bytes: Int32,
    wire_version: UInt64,
    shared_data_version: UInt64,
    bucket_count: UInt64,
    dynamic_paths: Array(String),
    statistics_present: Bool,
    statistics_counts: Array(UInt64),
    statistics_shared: Array(NamedTuple(name: String, count: UInt64)),
    callback_schedule_matches_mrk4: Bool?,
    object_sites: Array(PersistedObjectSite),
    shards: Array(NamedTuple(slot: Int32, stream: String?, bytes: Int32, logical_start: Int64, logical_end: Int64)),
  )
  alias PersistedSiteMark = NamedTuple(
    callback_schedule_matches_mrk4: Bool?,
    object_sites: Array(PersistedObjectSite),
  )
  alias PersistedLayout = NamedTuple(mode: String, granules: Array(PersistedGranule))

  private def self.expected_labels : Array(String)
    layouts = [
      {"v1", "v1", "map"}, {"v2", "v2", "map"},
      {"v3", "v3", "map"}, {"v3", "v3", "map_with_buckets"},
      {"v3", "v3", "advanced"}, {"v3", "v3", "advanced_chunked"},
    ]
    labels = [] of String
    layouts.each do |object_version, dynamic_version, layout|
      [3, 4].each do |mark|
        [0, 1].each do |string_version|
          ["basic", "compact"].each do |variant_mode|
            labels << "obj_#{object_version}_dyn_#{dynamic_version}_#{layout}_mrk#{mark}_s#{string_version}_variant_#{variant_mode}"
          end
        end
      end
    end
    labels
  end

  private def self.read_pk(api : String, part : String) : Array(UInt64)
    values = [] of UInt64
    if api == "compact"
      table = CrystalClick::CompactPartTable.open_selected_typed([part], ["pk"])
      table.scan_typed { |batch| values.concat(batch.values_for("pk", UInt64).to_a) }
    elsif api == "typed"
      table = CrystalClick::TypedPartTable.open_selected_typed([part], ["pk"])
      table.scan_typed { |batch| values.concat(batch.values_for("pk", UInt64).to_a) }
    else
      raise "unknown W263 public API #{api.inspect}"
    end
    values
  end

  private def self.expect_refusal(api : String, part : String, column : String) : String
    begin
      if api == "compact"
        CrystalClick::CompactPartTable.open_selected_typed([part], [column])
      elsif api == "typed"
        CrystalClick::TypedPartTable.open_selected_typed([part], [column])
      else
        raise "unknown W263 public API #{api.inspect}"
      end
    rescue ex : CrystalClick::UnsupportedFormatError
      error = ex.message || ""
      raise "W263 #{api}/#{column} refusal differs: #{error.inspect}" unless error == REFUSAL
      return error
    end
    raise "W263 #{api}/#{column} unexpectedly admitted JSON before the production change"
  end

  private def self.expect_offline_wrapper_refusal(store_root : String, table_name : String, column : String) : NamedTuple(
    column: String,
    error_class: String,
    error: String,
  )
    begin
      CrystalClick::OfflineCatalog.open(store_root)["default"][table_name][column].values
    rescue ex : CrystalClick::UnsupportedFormatError
      error = ex.message || ""
      unless error == "selected table column type is unsupported"
        raise "W263 offline #{column}.values refusal differs: #{error.inspect}"
      end
      return {column: column, error_class: "UnsupportedFormatError", error: error}
    end
    raise "W263 offline #{column}.values unexpectedly admitted before the production change"
  end

  private def self.read_signatures(values : Slice(CrystalClick::BinaryValue)) : Array(String)
    values.map { |value| CompactJsonW263Fixture.value_signature(value) }.to_a
  end

  private def self.quoted(value : String) : String
    JSON::Any.new(value).to_json
  end

  private def self.document_signature(document : CrystalClick::ObjectDocument, declaration : String) : String
    entries = document.paths.map do |path|
      "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
    end
    "#{declaration}{#{entries.join(",")}}"
  end

  private def self.variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "Variant(String, UInt64)#0(String:#{quoted(value)})"
    when UInt64
      "Variant(String, UInt64)#1(UInt64:#{value})"
    else
      "Variant(String, UInt64)#255(NULL)"
    end
  end

  private def self.recursive_signature(
    schema : CrystalClick::StorageColumnSchema,
    value : CrystalClick::StorageColumnValue,
  ) : String
    if schema.tuple?
      raise CrystalClick::CorruptPartError.new("W263 recursive Tuple value/schema arity differs") unless value.tuple? && schema.child_count == value.child_count
      children = schema.child_count.times.map do |index|
        recursive_signature(schema.child_at(index), value.child_at(index))
      end
      "#{schema.declaration}(#{children.join(",")})"
    elsif schema.array?
      raise CrystalClick::CorruptPartError.new("W263 recursive Array value/schema differs") unless value.array?
      children = value.array_values.map { |child| recursive_signature(schema.child_at(0), child) }
      "#{schema.declaration}[#{children.join(";")}]"
    elsif schema.object?
      raise CrystalClick::CorruptPartError.new("W263 recursive JSON leaf differs") unless value.object?
      document_signature(value.object_document, schema.object_schema.declaration)
    elsif schema.bulk?
      raise CrystalClick::CorruptPartError.new("W263 recursive BinaryBulk leaf differs") unless value.bulk?
      CompactJsonW263Fixture.value_signature(value.bulk_value)
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 recursive signature has an unknown schema node")
    end
  end

  private def self.append_column_signatures(
    signatures : Array(String),
    batch : CrystalClick::WidePartTableBatch,
    column : String,
    schema : CrystalClick::StorageColumnSchema,
  ) : Nil
    case column
    when "scalar"
      batch.values_for(column, UInt8).each { |value| signatures << "UInt8:#{value}" }
    when "text"
      batch.strings_for(column).each { |value| signatures << "String:#{quoted(value)}" }
    when "payload"
      signatures.concat(read_signatures(batch.binary_bulk_values_for(column)))
    when "choice"
      batch.variant_string_uint64_for(column).each { |value| signatures << variant_signature(value) }
    when "root"
      batch.object_documents_for(column).each do |document|
        signatures << document_signature(document, CompactJsonW263Fixture.json_type.name)
      end
    when "docs"
      batch.array_object_documents_for(column).each do |documents|
        children = documents.map do |document|
          document_signature(document, CompactJsonW263Fixture.json_type.name)
        end
        signatures << "#{CompactJsonW263Fixture.docs_type.name}[#{children.join(";")}]"
      end
    when "tagged", "pair"
      batch.recursive_values_for(column).each do |value|
        signatures << recursive_signature(schema, value)
      end
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 has no typed public carrier for #{column}")
    end
    nil
  end

  private def self.capture_persisted_layout(
    part : String,
    label : String,
    part_paths : Hash(String, String),
  ) : PersistedLayout
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    site_marks = if label.includes?("_advanced_chunked_")
                   peer_label = if label.includes?("_mrk3_")
                                  label.sub("_mrk3_", "_mrk4_")
                                else
                                  label.sub("_mrk4_", "_mrk3_")
                                end
                   peer_part = part_paths[peer_label]? || raise CrystalClick::CorruptPartError.new("W263 chunked part lacks its paired mark format")
                   capture_chunked_site_marks(physical, peer_part)
                 else
                   Array(PersistedSiteMark).new(physical.granule_count) do
                     {callback_schedule_matches_mrk4: nil, object_sites: [] of PersistedObjectSite}
                   end
                 end
    window = physical.read_window("root", 0, physical.granule_count)
    granules = window.granules.map_with_index do |granule, mark_index|
      shards = granule.shards
      first = shards.first? || raise CrystalClick::CorruptPartError.new("W263 root has no physical shards")
      if window.mode.mrk4? && first.stream_name != "root.object_structure"
        raise CrystalClick::CorruptPartError.new("W263 mrk4 root first callback is not root.object_structure")
      end
      codec = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, first.bytes)
      structure = CrystalClick::ObjectStructureCodec.read_from(codec)
      codec.ensure_consumed if window.mode.mrk4?
      statistics = structure.statistics
      shared = [] of NamedTuple(name: String, count: UInt64)
      counts = [] of UInt64
      if statistics
        counts = statistics.counts
        statistics.shared.each { |entry| shared << {name: entry.name, count: entry.count} }
      end
      shard_rows = shards.map do |shard|
        {slot: shard.slot_index, stream: shard.stream_name, bytes: shard.bytes.size.to_i32,
         logical_start: shard.logical_start, logical_end: shard.logical_end}
      end
      {
        mark: granule.mark,
        row_offset: granule.row_offset,
        row_count: granule.row_count,
        first_stream: first.stream_name,
        structure_prefix_bytes: codec.input_offset,
        wire_version: structure.version,
        shared_data_version: structure.shared_data_version,
        bucket_count: structure.bucket_count,
        dynamic_paths: structure.dynamic_paths,
        statistics_present: !statistics.nil?,
        statistics_counts: counts,
        statistics_shared: shared,
        callback_schedule_matches_mrk4: site_marks[mark_index][:callback_schedule_matches_mrk4],
        object_sites: site_marks[mark_index][:object_sites],
        shards: shard_rows,
      }
    end
    {mode: window.mode.to_s.downcase, granules: granules}
  end

  private def self.capture_chunked_site_marks(
    current : CrystalClick::CompactPartPhysicalContext,
    peer_part : String,
  ) : Array(PersistedSiteMark)
    peer = CrystalClick::CompactPartPhysicalContext.open(peer_part)
    mrk3, mrk4 = if current.mode.mrk3?
                   {current, peer}
                 else
                   {peer, current}
                 end
    unless mrk3.mode.mrk3? && mrk4.mode.mrk4? && mrk3.granule_count == mrk4.granule_count
      raise CrystalClick::CorruptPartError.new("W263 paired CHUNKED mark formats differ")
    end
    unless mrk3.mark_row_counts == mrk4.mark_row_counts
      raise CrystalClick::CorruptPartError.new("W263 paired CHUNKED row grids differ")
    end
    mark_row_counts = mrk4.mark_row_counts

    columns = ["root", "docs", "tagged", "pair"]
    mrk3_windows = Hash(String, CrystalClick::CompactPartPhysicalWindow).new
    mrk4_windows = Hash(String, CrystalClick::CompactPartPhysicalWindow).new
    columns.each do |column|
      mrk3_windows[column] = mrk3.read_window(column, 0, mrk3.granule_count)
      mrk4_windows[column] = mrk4.read_window(column, 0, mrk4.granule_count)
    end

    results = Array(PersistedSiteMark).new(mrk3.granule_count)
    mrk3.granule_count.times do |mark_index|
      sites = [] of PersistedObjectSite
      columns.each do |column|
        old_mark = mrk3_windows[column].granules[mark_index]
        named_mark = mrk4_windows[column].granules[mark_index]
        unless old_mark.shards.size == 1
          raise CrystalClick::CorruptPartError.new("W263 mrk3 CHUNKED column is not one whole-column tape")
        end
        whole_tape = IO::Memory.new
        named_mark.shards.each do |shard|
          unless shard.stream_name
            raise CrystalClick::CorruptPartError.new("W263 mrk4 CHUNKED callback lacks its physical stream name")
          end
          whole_tape.write(shard.bytes)
        end
        unless old_mark.shards[0].bytes == whole_tape.to_slice
          raise CrystalClick::CorruptPartError.new("W263 paired CHUNKED mrk3 tape differs from ordered mrk4 callbacks")
        end

        stream_map = Hash(String, CrystalClick::CompactPartPhysicalShard).new
        callback_order = [] of String
        named_mark.shards.each do |shard|
          stream = shard.stream_name || raise CrystalClick::CorruptPartError.new("W263 mrk4 callback name is absent")
          callback_order << stream
          stream_map[stream] = shard
        end
        owners = case column
                 when "root"  then ["root"]
                 when "docs"  then ["docs"]
                 when "tagged" then ["tagged%2Edoc"]
                 when "pair"  then ["pair%2Eleft", "pair%2Eright"]
                 else raise CrystalClick::CorruptPartError.new("W263 chunked site column is not admitted")
                 end
        owners.each do |owner|
          sites << capture_chunked_object_site(
            column,
            owner,
            mark_index,
            mark_row_counts[mark_index],
            callback_order,
            stream_map,
          )
        end
      end
      results << {callback_schedule_matches_mrk4: true, object_sites: sites}
    end
    results
  end

  private def self.capture_chunked_object_site(
    column : String,
    owner : String,
    mark_index : Int,
    parent_row_count : UInt64,
    callback_order : Array(String),
    streams : Hash(String, CrystalClick::CompactPartPhysicalShard),
  ) : PersistedObjectSite
    array_size_witness = if column == "docs" || column == "tagged"
                           stream_name = "#{column}.size0"
                           size_shard = streams[stream_name]? || raise CrystalClick::CorruptPartError.new("W263 outer Array size callback is absent")
                           callback_index = callback_order.index(stream_name) || raise CrystalClick::CorruptPartError.new("W263 outer Array size callback is absent from the persisted schedule")
                           occurrences = read_compact_array_size0(size_shard, stream_name, parent_row_count)
                           {
                             wrapper_stream: stream_name,
                             source_mark_format: "mrk4",
                             wrapper_callback_index: callback_index.to_i32,
                             wrapper_callback_schedule: callback_order,
                             parent_row_count: parent_row_count,
                             logical_start: size_shard.logical_start,
                             logical_end: size_shard.logical_end,
                             occurrences_by_parent: occurrences,
                           }
                         else
                           nil
                         end
    # Array size lanes belong to the outer wrapper, not the nested Object
    # site's callback schedule. This explicit exclusion matters for `docs`,
    # where both names share the same textual column prefix.
    schedule = callback_order.select { |stream| stream.starts_with?("#{owner}.") }
    if witness = array_size_witness
      schedule.reject! { |stream| stream == witness[:wrapper_stream] }
    end
    structure_name = "#{owner}.object_structure"
    structure_shard = streams[structure_name]? || raise CrystalClick::CorruptPartError.new("W263 chunked Object structure callback is absent")
    structure_codec = CrystalClick::BinaryCodecContext.new(
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      structure_shard.bytes,
    )
    # The selected docs/tagged/pair Object callbacks are static nested
    # serializers, not the statistics-free Object-substream context. Array
    # and Tuple bulk-prefix methods forward the same Compact settings to their
    # children, so every captured structure shard includes PREFIX or
    # PREFIX_EMPTY statistics and must use the complete decoder.
    structure = CrystalClick::ObjectStructureCodec.read_from(structure_codec)
    structure_codec.ensure_consumed
    unless structure.version == 4_u64 && structure.shared_data_version == 3_u64 && structure.bucket_count == 2_u64
      raise CrystalClick::CorruptPartError.new("W263 nested CHUNKED Object structure layout differs")
    end
    parent_occurrence_source = if array_size_witness
                                 "outer_array_size0"
                               else
                                 "one_object_per_parent_row"
                               end
    parent_row_occurrences = if witness = array_size_witness
                               witness[:occurrences_by_parent]
                             else
                               expected_single_object_occurrences_by_row(column, owner, parent_row_count)
                             end
    expected_rows = sum_u64(parent_row_occurrences)

    buckets = Array(PersistedBucket).new(structure.bucket_count.to_i)
    structure.bucket_count.to_i.times do |bucket_index|
      prefix_name = "#{owner}.object_shared_data.#{bucket_index}.structure_prefix"
      suffix_name = "#{owner}.object_shared_data.#{bucket_index}.structure_suffix"
      prefix = streams[prefix_name]? || raise CrystalClick::CorruptPartError.new("W263 CHUNKED Object StructurePrefix callback is absent")
      suffix = streams[suffix_name]? || raise CrystalClick::CorruptPartError.new("W263 CHUNKED Object StructureSuffix callback is absent")
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      records = CrystalClick::ObjectSharedChunkStructureCodec.read_split_records(
        prefix.bytes,
        suffix.bytes,
        budget,
      )
      observed_rows = records.sum(&.row_count)
      unless observed_rows == expected_rows && records.size.to_u64 == expected_rows && records.all? { |record| record.row_count == 1_u64 }
        raise CrystalClick::CorruptPartError.new("W263 persisted CHUNKED records do not match one-row fixture occurrences")
      end
      chunks = records.map do |record|
        {
          row_count: record.row_count,
          paths: record.paths,
          data_marks: record.data_marks,
          paths_marks: record.paths_marks,
          paths_substreams_metadata_marks: record.paths_substreams_metadata_marks,
        }
      end
      buckets << {bucket: bucket_index.to_i32, chunks: chunks}
    end

    {
      column: column,
      owner: owner,
      callback_order: schedule,
      parent_occurrence_source: parent_occurrence_source,
      parent_row_occurrences: parent_row_occurrences,
      array_size_witness: array_size_witness,
      wire_version: structure.version,
      shared_data_version: structure.shared_data_version,
      bucket_count: structure.bucket_count,
      dynamic_paths: structure.dynamic_paths,
      buckets: buckets,
    }
  end

  private def self.expected_single_object_occurrences_by_row(
    column : String,
    owner : String,
    parent_row_count : UInt64,
  ) : Array(UInt64)
    unless column == "root" || (column == "pair" && {"pair%2Eleft", "pair%2Eright"}.includes?(owner))
      raise CrystalClick::CorruptPartError.new("W263 non-array Object site lacks its per-parent occurrence rule")
    end
    if parent_row_count > Int32::MAX.to_u64
      raise CrystalClick::CorruptPartError.new("W263 parent row count exceeds the helper domain")
    end
    Array(UInt64).new(parent_row_count.to_i, 1_u64)
  end

  # Compact's position-independent ArraySizes lane stores one little-endian
  # UInt64 size (the delta from the previous offset) for each physical parent
  # row. `parent_row_count` comes from the saved Compact mark grid; the bytes
  # are the exact named mrk4 callback shard for the outer wrapper.
  private def self.read_compact_array_size0(
    shard : CrystalClick::CompactPartPhysicalShard,
    expected_stream : String,
    parent_row_count : UInt64,
  ) : Array(UInt64)
    unless shard.stream_name == expected_stream
      raise CrystalClick::CorruptPartError.new("W263 outer Array size shard identity differs")
    end
    if parent_row_count > (Int32::MAX // 8).to_u64
      raise CrystalClick::CorruptPartError.new("W263 outer Array size schedule exceeds the helper domain")
    end
    expected_bytes = parent_row_count * 8_u64
    if (shard.logical_end - shard.logical_start).to_u64 != expected_bytes
      raise CrystalClick::CorruptPartError.new("W263 outer Array size interval differs from its parent row grid")
    end
    bytes = shard.bytes
    unless bytes.size.to_u64 == expected_bytes
      raise CrystalClick::CorruptPartError.new("W263 outer Array size bytes differ from their physical interval")
    end

    values = Array(UInt64).new(parent_row_count.to_i)
    parent_row_count.to_i.times do |row_index|
      offset = row_index * 8
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      values << value
    end
    values
  end

  private def self.sum_u64(values : Array(UInt64)) : UInt64
    total = 0_u64
    values.each do |value|
      if value > UInt64::MAX - total
        raise CrystalClick::CorruptPartError.new("W263 parent occurrence total overflows UInt64")
      end
      total += value
    end
    total
  end

  private def self.value_scan(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    columns : Array(String),
    start_row : UInt64,
    max_rows : Int,
  ) : Scan
    keys = [] of UInt64
    signatures = Hash(String, Array(String)).new
    columns.each { |column| signatures[column] = [] of String }
    table.scan_typed_window(start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk", UInt64).to_a)
      columns.each do |column|
        schema = if column == "tagged"
                   CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.tagged_type.name)
                 elsif column == "pair"
                   CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.pair_type.name)
                 else
                   CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.json_type.name)
                 end
        append_column_signatures(signatures[column], batch, column, schema)
      end
    end
    {keys: keys, columns: signatures}
  end

  private def self.public_report(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    columns : Array(String),
  ) : Report
    marks = table.part_mark_row_counts
    unless marks == [CompactJsonW263Fixture::MARK_ROWS]
      raise "W263 public mark grid differs: #{marks.inspect}"
    end
    raise "W263 public row count differs" unless table.total_row_count == 8_u64
    # EOF-first tests that the full physical prefix/site schedule is validated
    # even when the requested row window is empty.
    eof = value_scan(table, columns, 8_u64, 1)
    {
      mark_rows: marks,
      full: value_scan(table, columns, 0_u64, 8),
      first: value_scan(table, columns, 0_u64, 2),
      middle: value_scan(table, columns, 2_u64, 4),
      last: value_scan(table, columns, 6_u64, 2),
      eof: eof,
    }
  end

  private def self.offline_signatures(store_root : String, table_name : String, column : String) : Array(String)
    values = CrystalClick::OfflineCatalog.open(store_root)["default"][table_name][column].values
    values.map do |value|
      offline_value_signature(value, column)
    end
  end

  # Keep future recursive carriers in this local checked domain without
  # widening OfflineColumnValue before the production materializer admits
  # them. Against today's baseline the `as?` checks fail explicitly; once the
  # public union adds a carrier, this same branch narrows and validates it.
  private def self.offline_value_signature(
    value : CrystalClick::OfflineColumnValue | Array(CrystalClick::ObjectDocument) | CrystalClick::StorageColumnValue,
    column : String,
  ) : String
    case column
    when "scalar"
      "UInt8:#{value.as(UInt8)}"
    when "text"
      "String:#{quoted(value.as(String))}"
    when "payload"
      CompactJsonW263Fixture.value_signature(value.as(CrystalClick::BinaryValue))
    when "choice"
      raw = value.as?(String | UInt64) || raise CrystalClick::CorruptPartError.new("W263 offline Variant carrier differs")
      variant_signature(raw)
    when "root"
      document_signature(value.as(CrystalClick::ObjectDocument), CompactJsonW263Fixture.json_type.name)
    when "docs"
      documents = value.as?(Array(CrystalClick::ObjectDocument)) ||
                  raise CrystalClick::UnsupportedFormatError.new("W263 offline docs carrier missing: expected Array(ObjectDocument)")
      children = documents.map do |document|
        document_signature(document, CompactJsonW263Fixture.json_type.name)
      end
      "#{CompactJsonW263Fixture.docs_type.name}[#{children.join(";")}]"
    when "tagged"
      schema = CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.tagged_type.name)
      recursive = value.as?(CrystalClick::StorageColumnValue) ||
                  raise CrystalClick::UnsupportedFormatError.new("W263 offline tagged carrier missing: expected StorageColumnValue")
      recursive_signature(schema, recursive)
    when "pair"
      schema = CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.pair_type.name)
      recursive = value.as?(CrystalClick::StorageColumnValue) ||
                  raise CrystalClick::UnsupportedFormatError.new("W263 offline pair carrier missing: expected StorageColumnValue")
      recursive_signature(schema, recursive)
    else
      raise CrystalClick::UnsupportedFormatError.new("W263 offline API has no W263 #{column} carrier")
    end
  end

  private def self.write_layout(json : JSON::Builder, layout : PersistedLayout) : Nil
    json.object do
      json.field "mark_format", layout[:mode]
      json.field "granules" do
        json.array do
          layout[:granules].each do |granule|
            json.object do
              json.field "mark", granule[:mark]
              json.field "row_offset", granule[:row_offset]
              json.field "row_count", granule[:row_count]
              json.field "first_stream", granule[:first_stream]
              json.field "structure_prefix_bytes", granule[:structure_prefix_bytes]
              json.field "wire_version", granule[:wire_version]
              json.field "shared_data_version", granule[:shared_data_version]
              json.field "bucket_count", granule[:bucket_count]
              json.field "dynamic_paths", granule[:dynamic_paths]
              json.field "statistics_present", granule[:statistics_present]
              json.field "statistics_counts", granule[:statistics_counts]
              json.field "statistics_shared" do
                json.array do
                  granule[:statistics_shared].each do |entry|
                    json.object do
                      json.field "name", entry[:name]
                      json.field "count", entry[:count]
                    end
                  end
                end
              end
              json.field "callback_schedule_matches_mrk4", granule[:callback_schedule_matches_mrk4]
              json.field "object_sites" do
                json.array do
                  granule[:object_sites].each do |site|
                    json.object do
                      json.field "column", site[:column]
                      json.field "owner", site[:owner]
                      json.field "callback_order", site[:callback_order]
                      json.field "parent_occurrence_source", site[:parent_occurrence_source]
                      json.field "parent_row_occurrences", site[:parent_row_occurrences]
                      if witness = site[:array_size_witness]
                        json.field "array_size_witness" do
                          json.object do
                            json.field "wrapper_stream", witness[:wrapper_stream]
                            json.field "source_mark_format", witness[:source_mark_format]
                            json.field "wrapper_callback_index", witness[:wrapper_callback_index]
                            json.field "wrapper_callback_schedule", witness[:wrapper_callback_schedule]
                            json.field "parent_row_count", witness[:parent_row_count]
                            json.field "logical_start", witness[:logical_start]
                            json.field "logical_end", witness[:logical_end]
                            json.field "occurrences_by_parent", witness[:occurrences_by_parent]
                          end
                        end
                      else
                        json.field "array_size_witness", nil
                      end
                      json.field "wire_version", site[:wire_version]
                      json.field "shared_data_version", site[:shared_data_version]
                      json.field "bucket_count", site[:bucket_count]
                      json.field "dynamic_paths", site[:dynamic_paths]
                      json.field "buckets" do
                        json.array do
                          site[:buckets].each do |bucket|
                            json.object do
                              json.field "bucket", bucket[:bucket]
                              json.field "chunks" do
                                json.array do
                                  bucket[:chunks].each do |chunk|
                                    json.object do
                                      json.field "row_count", chunk[:row_count]
                                      json.field "paths", chunk[:paths]
                                      {"data_marks" => chunk[:data_marks],
                                       "paths_marks" => chunk[:paths_marks],
                                       "paths_substreams_metadata_marks" => chunk[:paths_substreams_metadata_marks]}.each do |name, pair|
                                        json.field name, [pair[0], pair[1]]
                                      end
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
              json.field "shards" do
                json.array do
                  granule[:shards].each do |shard|
                    json.object do
                      json.field "slot", shard[:slot]
                      json.field "stream", shard[:stream]
                      json.field "bytes", shard[:bytes]
                      json.field "logical_start", shard[:logical_start]
                      json.field "logical_end", shard[:logical_end]
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    nil
  end

  private def self.part_paths(parts : Array(JSON::Any)) : Hash(String, String)
    paths = Hash(String, String).new(initial_capacity: parts.size)
    parts.each do |entry|
      label = entry["label"].as_s
      if paths.has_key?(label)
        raise "W263 manifest repeats part label #{label}"
      end
      paths[label] = File.expand_path(entry["path"].as_s)
    end
    paths
  end

  private def self.read_manifest(path : String) : NamedTuple(store_root: String, parts: Array(JSON::Any))
    manifest = JSON.parse(File.read(path)).as_h
    raise "wrong W263 native manifest format" unless manifest["format"].as_s == MANIFEST_FORMAT
    labels = manifest["parts"].as_a.map { |entry| entry["label"].as_s }
    expected = expected_labels
    unless labels == expected && labels.uniq.size == 48
      raise "W263 manifest does not contain the exact ordered 48-cell matrix"
    end
    {store_root: File.expand_path(manifest["store_root"].as_s), parts: manifest["parts"].as_a}
  end

  def self.run(manifest_path : String) : Nil
    manifest = read_manifest(manifest_path)
    paths = part_paths(manifest[:parts])
    cells = [] of NamedTuple(
      label: String,
      compact_pk: Array(UInt64),
      typed_pk: Array(UInt64),
      layout: PersistedLayout,
      refusals: Array(NamedTuple(api: String, column: String, error: String)),
      offline_wrapper_refusals: Array(NamedTuple(column: String, error_class: String, error: String)),
    )
    manifest[:parts].each do |entry|
      label = entry["label"].as_s
      part = File.expand_path(entry["path"].as_s)
      unless File.directory?(part) && !File.symlink?(part)
        raise "W263 #{label} part path is absent or linked"
      end
      compact_pk = read_pk("compact", part)
      typed_pk = read_pk("typed", part)
      layout = capture_persisted_layout(part, label, paths)
      expected_pk = (1_u64..8_u64).to_a
      unless compact_pk == expected_pk && typed_pk == expected_pk
        raise "W263 #{label} UInt64 positive read differs: compact=#{compact_pk.inspect}, typed=#{typed_pk.inspect}"
      end
      refusals = [] of NamedTuple(api: String, column: String, error: String)
      JSON_COLUMNS.each do |column|
        {"compact", "typed"}.each do |api|
          refusals << {api: api, column: column, error: expect_refusal(api, part, column)}
        end
      end
      offline_wrapper_refusals = OFFLINE_WRAPPER_COLUMNS.map do |column|
        expect_offline_wrapper_refusal(manifest[:store_root], entry["table"].as_s, column)
      end
      cells << {label: label, compact_pk: compact_pk, typed_pk: typed_pk, layout: layout,
                refusals: refusals, offline_wrapper_refusals: offline_wrapper_refusals}
    end
    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "status", "expected_unsupported"
        json.field "cells" do
          json.array do
            cells.each do |cell|
              json.object do
                json.field "label", cell[:label]
                json.field "compact_pk", cell[:compact_pk]
                json.field "typed_pk", cell[:typed_pk]
                json.field "persisted_root_layout" do
                  write_layout(json, cell[:layout])
                end
                json.field "refusals" do
                  json.array do
                    cell[:refusals].each do |refusal|
                      json.object do
                        json.field "api", refusal[:api]
                        json.field "column", refusal[:column]
                        json.field "error_class", "UnsupportedFormatError"
                        json.field "error", refusal[:error]
                      end
                    end
                  end
                end
                json.field "offline_wrapper_refusals" do
                  json.array do
                    cell[:offline_wrapper_refusals].each do |refusal|
                      json.object do
                        json.field "column", refusal[:column]
                        json.field "error_class", refusal[:error_class]
                        json.field "error", refusal[:error]
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
  end

  def self.run_green(manifest_path : String) : Nil
    manifest = read_manifest(manifest_path)
    paths = part_paths(manifest[:parts])
    cells = [] of NamedTuple(
      label: String,
      compact_pk: Array(UInt64),
      typed_pk: Array(UInt64),
      layout: PersistedLayout,
      compact: Report,
      typed: Report,
      offline: Hash(String, Array(String)),
    )
    manifest[:parts].each do |entry|
      label = entry["label"].as_s
      part = File.expand_path(entry["path"].as_s)
      table_name = entry["table"].as_s
      unless File.directory?(part) && !File.symlink?(part)
        raise "W263 #{label} part path is absent or linked"
      end
      compact_pk = read_pk("compact", part)
      typed_pk = read_pk("typed", part)
      layout = capture_persisted_layout(part, label, paths)
      expected_pk = (1_u64..8_u64).to_a
      unless compact_pk == expected_pk && typed_pk == expected_pk
        raise "W263 #{label} UInt64 positive read differs"
      end
      compact_table = CrystalClick::CompactPartTable.open_selected_typed([part], ["pk"] + GREEN_COLUMNS)
      typed_table = CrystalClick::TypedPartTable.open_selected_typed([part], ["pk"] + GREEN_COLUMNS)
      compact = public_report(compact_table, GREEN_COLUMNS)
      typed = public_report(typed_table, GREEN_COLUMNS)
      offline = Hash(String, Array(String)).new
      OFFLINE_COLUMNS.each { |column| offline[column] = offline_signatures(manifest[:store_root], table_name, column) }
      cells << {label: label, compact_pk: compact_pk, typed_pk: typed_pk,
                layout: layout, compact: compact, typed: typed, offline: offline}
    end
    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", GREEN_FORMAT
        json.field "status", "green_candidate"
        json.field "cells" do
          json.array do
            cells.each do |cell|
              json.object do
                json.field "label", cell[:label]
                json.field "compact_pk", cell[:compact_pk]
                json.field "typed_pk", cell[:typed_pk]
                json.field "persisted_root_layout" do
                  write_layout(json, cell[:layout])
                end
                {"compact" => cell[:compact], "typed" => cell[:typed]}.each do |backend, report|
                  json.field backend do
                    json.object do
                      json.field "mark_rows", report[:mark_rows]
                      {"full" => report[:full], "first" => report[:first], "middle" => report[:middle],
                       "last" => report[:last], "eof" => report[:eof]}.each do |window, scan|
                        json.field window do
                          json.object do
                            json.field "keys", scan[:keys]
                            json.field "columns", scan[:columns]
                          end
                        end
                      end
                    end
                  end
                end
                json.field "offline" do
                  json.object do
                    json.field "supported_columns", OFFLINE_COLUMNS
                    cell[:offline].each { |column, values| json.field column, values }
                  end
                end
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
  end
end

unless ARGV.size == 2 && %w[baseline green].includes?(ARGV[0])
  abort "usage: check_compact_json_w263 baseline|green MANIFEST.json"
end

ARGV[0] == "baseline" ? CheckCompactJSONW263.run(ARGV[1]) : CheckCompactJSONW263.run_green(ARGV[1])
