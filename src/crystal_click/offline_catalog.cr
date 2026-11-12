require "./offline_column_value"
require "./offline_column"
require "./offline_projection"
require "./offline_part_candidate"
require "./offline_table_reference"
require "./offline_materialized_view_target"
require "./offline_materialized_view"
require "./offline_materialized_view_target_parser"
require "./offline_materialized_view_query_analyzer"
require "./offline_table"
require "./offline_column_selection"
require "./offline_database"

module CrystalClick
  # Offline reader for the bounded ClickHouse 26.7 Atomic metadata layout.
  # It reads local files only and does not emulate system.* tables or server
  # lifecycle state.
  class OfflineCatalog
    MAX_METADATA_ENTRIES              =    10_000
    MAX_METADATA_BYTES                = 1_048_576
    MAX_IDENTIFIER_BYTES              =     4_096
    MAX_COUNT_BYTES                   =        32
    MAX_PART_CANDIDATES               =   100_000
    SYSTEM_DATABASE_NAME              = "system"
    SYSTEM_PART_CANDIDATES_TABLE_NAME = "part_candidates"
    TABLE_TAIL_CLAUSE_PATTERN         = /\A(PARTITION\s+BY|ORDER\s+BY|PRIMARY\s+KEY|SAMPLE\s+BY|TTL|SETTINGS|COMMENT)\b/i

    getter root : String

    def self.open(root : String) : OfflineCatalog
      new(root)
    end

    def initialize(root : String)
      expanded = File.expand_path(root)
      raise InvalidPartError.new("offline data root is a symbolic link") if File.symlink?(expanded)
      raise InvalidPartError.new("offline data root is not a directory") unless Dir.exists?(expanded)

      @root = canonical_root(expanded)
      raise InvalidPartError.new("offline data root cannot be the filesystem root") if @root == "/"
      validate_directory(File.join(@root, "metadata"), "metadata root")
      validate_directory(File.join(@root, "store"), "store root")
    end

    def database_names : Array(String)
      metadata_root = File.join(@root, "metadata")
      children = bounded_children(metadata_root, MAX_METADATA_ENTRIES, "database metadata entries")
      names = Array(String).new
      seen = Set(String).new

      children.each do |entry|
        next unless entry.ends_with?(".sql")

        path = File.join(metadata_root, entry)
        raise InvalidPartError.new("database DDL is a symbolic link: #{entry}") if File.symlink?(path)
        raise InvalidPartError.new("database DDL is not a regular file: #{entry}") unless File.file?(path)

        encoded_name = entry.byte_slice(0, entry.bytesize - 4)
        name = decode_identifier(encoded_name, "database metadata filename")
        raise InvalidPartError.new("duplicate decoded database name: #{name}") if seen.includes?(name)
        seen << name
        names << name
      end

      children.each do |entry|
        next if entry.ends_with?(".sql")

        path = File.join(metadata_root, entry)
        if entry == "default" && File.symlink?(path)
          uuid = uuid_from_metadata_link(path)
          validate_store_directory(uuid)
          unless seen.includes?("default")
            names << "default"
            seen << "default"
          end
        elsif File.symlink?(path) && seen.includes?(decode_identifier(entry, "database metadata alias"))
          # Non-default metadata/<database> links are ClickHouse convenience
          # links; table lookup validates them against the DDL UUID before use.
          next
        else
          raise InvalidPartError.new("unexpected entry in database metadata root: #{entry}")
        end
      end

      names.sort!
      names
    end

    def databases : Array(OfflineDatabase)
      names = database_names
      known_names = Set(String).new
      names.each { |name| known_names << name }
      names.map do |name|
        location = resolve_database(name, known_names)
        OfflineDatabase.new(self, name, location.uuid)
      end
    end

    def database(name : String) : OfflineDatabase
      validate_identifier(name, "database name")
      if name == SYSTEM_DATABASE_NAME
        raise InvalidPartError.new("physical database named system collides with the synthetic system database") if database_names.includes?(SYSTEM_DATABASE_NAME)
        return OfflineDatabase.new(self, SYSTEM_DATABASE_NAME, nil, true)
      end

      location = resolve_database(name)
      OfflineDatabase.new(self, name, location.uuid)
    end

    def [](name : String) : OfflineDatabase
      database(name)
    end

    def table_names(database : String) : Array(String)
      return self.database(database).table_names if database == SYSTEM_DATABASE_NAME

      location = resolve_database(database)
      list_table_names(location)
    end

    def table_names(database : OfflineDatabase) : Array(String)
      validate_database_owner!(database)
      if database.virtual_system?
        validate_virtual_system_database!(database)
        return [SYSTEM_PART_CANDIDATES_TABLE_NAME]
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      list_table_names(location)
    end

    def tables(database : OfflineDatabase) : Array(OfflineTable)
      validate_database_owner!(database)
      if database.virtual_system?
        validate_virtual_system_database!(database)
        return [part_candidates_table]
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      names = list_table_names(location)
      known_names = Set(String).new
      names.each { |name| known_names << name }
      result = Array(OfflineTable).new(names.size)
      names.each do |name|
        result << table(location, name, known_names)
      end
      result
    end

    # Materialize one selected column from the bounded synthetic
    # system.part_candidates projection. The result is owned by the caller and
    # returned only after all supported source tables, counts, and overlap
    # guards pass.
    def part_candidates_values(
      column_name : String,
      max_rows : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ROWS,
      max_string_bytes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
    ) : Array(OfflineColumnValue)
      unless {"database", "table", "name", "partition_id", "rows"}.includes?(column_name)
        raise UnsupportedFormatError.new("selected system.part_candidates column is unsupported")
      end
      raise BoundsError.new("selected column row limit exceeds hard limit") if max_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS
      raise BoundsError.new("selected column String payload limit exceeds hard limit") if max_string_bytes > OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES
      database_names = self.database_names
      if database_names.includes?(SYSTEM_DATABASE_NAME)
        raise InvalidPartError.new("physical database named system collides with the synthetic system database")
      end

      parts = Array({String, String, OfflinePartCandidate}).new
      known_database_names = Set(String).new
      database_names.each { |name| known_database_names << name }

      database_names.each do |database_name|
        location = resolve_database(database_name, known_database_names)
        table_names = list_table_names(location)
        known_table_names = Set(String).new
        table_names.each { |name| known_table_names << name }

        table_names.each do |table_name|
          table = table(location, table_name, known_table_names, parts.size)
          if table.engine == "MergeTree"
            candidates = table.part_candidates
            reject_part_candidate_overlaps!(table.name, candidates)
            candidates.each do |candidate|
              if parts.size.to_u64 >= max_rows
                raise BoundsError.new("selected column materialization exceeds row limit")
              end
              ensure_candidate_capacity!(parts.size + 1)
              parts << {database_name, table.name, candidate}
            end
          elsif merge_tree_family_engine?(table.engine)
            raise UnsupportedFormatError.new("system.part_candidates does not support MergeTree-family engine: #{table.engine}")
          end
        end
      end

      values = Array(OfflineColumnValue).new(parts.size)
      string_bytes = 0_u64
      parts.each do |database_name, table_name, candidate|
        value = case column_name
                when "database"     then database_name
                when "table"        then table_name
                when "name"         then candidate.name
                when "partition_id" then candidate.info.partition_id
                when "rows"         then candidate.row_count
                else                     raise UnsupportedFormatError.new("selected system.part_candidates column is unsupported")
                end
        if string_value = value.as?(String)
          byte_count = string_value.bytesize.to_u64
          if string_bytes > max_string_bytes || byte_count > max_string_bytes - string_bytes
            raise BoundsError.new("selected column materialization exceeds String payload limit")
          end
          string_bytes += byte_count
          value = String.new(string_value.to_slice)
        end
        values << value
      end
      values
    end

    private def list_table_names(location : DatabaseLocation) : Array(String)
      children = bounded_children(location.metadata_path, MAX_METADATA_ENTRIES, "table metadata entries")
      names = Array(String).new
      seen = Set(String).new

      children.each do |entry|
        unless entry.ends_with?(".sql")
          raise InvalidPartError.new("unexpected entry in table metadata directory: #{entry}")
        end

        path = File.join(location.metadata_path, entry)
        raise InvalidPartError.new("table DDL is a symbolic link: #{entry}") if File.symlink?(path)
        raise InvalidPartError.new("table DDL is not a regular file: #{entry}") unless File.file?(path)

        encoded_name = entry.byte_slice(0, entry.bytesize - 4)
        name = decode_identifier(encoded_name, "table metadata filename")
        raise InvalidPartError.new("duplicate decoded table name: #{name}") if seen.includes?(name)
        seen << name
        names << name
      end

      names.sort!
      names
    end

    def table(database : String, name : String) : OfflineTable
      validate_identifier(name, "table name")
      return self.database(database).table(name) if database == SYSTEM_DATABASE_NAME

      location = resolve_database(database)
      table(location, name)
    end

    def table(database : OfflineDatabase, name : String) : OfflineTable
      validate_database_owner!(database)
      validate_identifier(name, "table name")
      if database.virtual_system?
        validate_virtual_system_database!(database)
        raise InvalidPartError.new("table does not exist: #{name}") unless name == SYSTEM_PART_CANDIDATES_TABLE_NAME
        return part_candidates_table
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      table(location, name)
    end

    # Resolve only the current local metadata identity declared by an MV.
    # This does not inspect activation, data contents, or the view UUID store.
    def resolve_materialized_view_target(database : String, view_name : String) : OfflineTable
      validate_identifier(view_name, "MATERIALIZED VIEW name")
      location = resolve_database(database)
      resolve_materialized_view_target(location, view_name)
    end

    def resolve_materialized_view_target(database : OfflineDatabase, view_name : String) : OfflineTable
      validate_database_owner!(database)
      validate_identifier(view_name, "MATERIALIZED VIEW name")
      if database.virtual_system?
        validate_virtual_system_database!(database)
        raise InvalidPartError.new("synthetic system database has no MATERIALIZED VIEW targets")
      end

      location = resolve_database(database.name)
      validate_database_identity!(database, location)
      resolve_materialized_view_target(location, view_name)
    end

    # Recompute one deliberately narrow persisted MATERIALIZED VIEW projection
    # from one resolved source part and publish it only below a detached/ path.
    # This is an offline artifact, not the server's current MV target state.
    # The caller must exclusively own the destination hierarchy during this
    # call: path-based checks do not prevent concurrent renames or symlink swaps.
    # A normal failure before atomic publish leaves no output; process death
    # after publish can leave a complete detached part that must be reconciled.
    def materialize_view_part(
      database : String,
      view_name : String,
      source_part_name : String,
      destination : String,
      rows_per_mark : Int32 = 8192,
    ) : String
      if rows_per_mark <= 0 || rows_per_mark > WidePartWriter::MAX_ROWS_PER_MARK
        raise BoundsError.new("rows_per_mark is out of range")
      end

      view = table(database, view_name)
      unless view.kind == :materialized_view && view.engine == "MaterializedView"
        raise UnsupportedFormatError.new("selected view is not a persisted MATERIALIZED VIEW")
      end

      target_database, target_name, source_database, source_name =
        parse_w88_materialized_view_identity(view.metadata_ddl || raise(UnsupportedFormatError.new("MATERIALIZED VIEW metadata is unavailable")))
      unless target_database == database && source_database == database
        raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW source and explicit TO target must use the selected database")
      end
      raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW source and target must be distinct tables") if source_name == target_name
      unless view.columns.empty? || w88_exact_view_columns?(view.columns)
        raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW columns must be exactly k UInt64, v String")
      end

      target = table(database, target_name)
      source = table(database, source_name)
      w88_validate_table_shape!(target, "target")
      w88_validate_table_shape!(source, "source")
      w88_validate_unpartitioned_layout!(target, "target")
      w88_validate_unpartitioned_layout!(source, "source")
      unless rows_per_mark == 8192
        raise UnsupportedFormatError.new("W88 rows_per_mark must match the supported target index_granularity of 8192")
      end

      output_path, output_info = w88_validate_detached_destination!(destination, target)
      target.part_candidates.each do |candidate|
        if candidate.info.overlaps?(output_info)
          raise InvalidPartError.new("W88 output part identity overlaps a target part candidate: #{candidate.name}")
        end
      end

      max_rows = OfflineTable::MAX_MATERIALIZED_VALUES_ROWS
      max_string_bytes = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES
      source_candidates = source.resolved_scan_parts
      selected = source_candidates.select { |candidate| candidate.name == source_part_name }
      unless selected.size == 1
        raise InvalidPartError.new("selected source part is absent or ambiguous in the resolved candidate set")
      end
      source_part = selected.first
      raise BoundsError.new("selected source part exceeds W88 row limit") if source_part.row_count > max_rows

      reader = WidePartTable.open_selected_typed([source_part.path], ["k", "v"])
      unless reader.columns == ["k", "v"] && reader.column_types == [{"k", "UInt64"}, {"v", "String"}]
        raise UnsupportedFormatError.new("selected source part physical types differ from exact W88 schema")
      end

      keys = Array(UInt64).new(source_part.row_count.to_i)
      values = Array(String).new(source_part.row_count.to_i)
      string_bytes = 0_u64
      previous_key : UInt64? = nil
      reader.scan_typed do |batch|
        batch_keys = batch.values_for("k")
        batch_values = batch.strings_for("v")
        unless batch_keys.size == batch_values.size
          raise CorruptPartError.new("selected W88 batch columns are not row-aligned")
        end
        batch_keys.each_with_index do |key, index|
          if previous = previous_key
            raise InvalidPartError.new("selected W88 source keys are not nondecreasing") if key < previous
          end
          value = batch_values[index]
          byte_count = value.bytesize.to_u64
          if string_bytes > max_string_bytes || byte_count > max_string_bytes - string_bytes
            raise BoundsError.new("selected W88 source String payload exceeds limit")
          end
          string_bytes += byte_count
          keys << key
          values << String.new(value.to_slice)
          previous_key = key
        end
      end

      unless keys.size.to_u64 == source_part.row_count && values.size == keys.size
        raise CorruptPartError.new("selected W88 source row count changed during scan")
      end

      WidePartWriter.write_uint64_typed_pair(
        output_path,
        "k",
        keys.to_unsafe.to_slice(keys.size),
        "v",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark
      )
    end

    # Run one caller-owned transformation over a single, catalog-resolved
    # source part and publish its typed output only below the resolved target's
    # detached directory. Persisted SELECT text is metadata; it is not run.
    def transform_materialized_view_part(
      database : String,
      view_name : String,
      source_part_name : String,
      source_columns : Array(String),
      output_part_name : String,
      rows_per_mark : Int32 = 8192,
      batch_rows : Int32 = WidePartTable::DEFAULT_BATCH_ROWS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      frame_bytes : Int = 4096,
      metadata_version : Int64 = 0_i64,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32 = 1,
      &callback : OfflinePartTransformInput -> WidePartTransformOutput
    ) : String
      operation, destination, schema_binding = prepare_materialized_view_part_transform(
        database,
        view_name,
        source_part_name,
        source_columns,
        output_part_name,
        rows_per_mark,
        batch_rows,
        false,
      )
      transform_validate_frame_bytes!(frame_bytes, transport_limits, false)
      output = operation.execute { |transform_input| yield transform_input }

      keys = output.keys
      columns = output.columns
      WidePartWriter.write_uint64_columns(
        destination,
        schema_binding.key_name,
        keys.to_unsafe.to_slice(keys.size),
        columns,
        rows_per_mark,
        profile,
        shared_profile,
        mode,
        frame_bytes,
        metadata_version,
        limits,
        transport_limits,
        shared_json_policy,
        shared_target_chunk_rows,
        [] of WidePartProjection,
        WidePartSchemaBinding.new(schema_binding),
      )
    end

    # Run one caller-owned transformation over the same catalog-resolved
    # source lifecycle, publishing the detached Compact owner output selected
    # by the required mark format.
    def transform_materialized_view_part(
      database : String,
      view_name : String,
      source_part_name : String,
      source_columns : Array(String),
      output_part_name : String,
      *,
      mark_format : CompactMarkFormat,
      rows_per_mark : Int32 = 8192,
      batch_rows : Int32 = WidePartTable::DEFAULT_BATCH_ROWS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      reader_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
      compress_marks : Bool = false,
      &callback : OfflinePartTransformInput -> CompactPartTransformOutput
    ) : String
      operation, destination, schema_binding = prepare_materialized_view_part_transform(
        database,
        view_name,
        source_part_name,
        source_columns,
        output_part_name,
        rows_per_mark,
        batch_rows,
        true,
        limits,
      )
      transform_validate_frame_bytes!(frame_bytes, transport_limits, true)
      output = operation.execute { |transform_input| yield transform_input }

      keys = output.keys
      columns = output.columns
      CompactPartWriter.write_uint64_columns(
        destination,
        schema_binding.key_name,
        keys.to_unsafe.to_slice(keys.size),
        columns,
        rows_per_mark,
        frame_bytes,
        limits,
        transport_limits,
        reader_limits,
        mark_format,
        variant_discriminator_mode,
        compress_marks,
        profile,
        schema_binding: schema_binding,
      )
    end

    private def prepare_materialized_view_part_transform(
      database : String,
      view_name : String,
      source_part_name : String,
      source_columns : Array(String),
      output_part_name : String,
      rows_per_mark : Int32,
      batch_rows : Int32,
      compact_output : Bool,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Tuple(OfflineMaterializedViewPartTransform, String, PartSchemaBinding)
      if rows_per_mark <= 0 || rows_per_mark > WidePartWriter::MAX_ROWS_PER_MARK
        raise BoundsError.new("rows_per_mark is out of range")
      end
      if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS
        raise BoundsError.new("transform batch_rows is out of range")
      end

      view = table(database, view_name)
      unless view.kind == :materialized_view && view.engine == "MaterializedView"
        raise UnsupportedFormatError.new("selected view is not a persisted MATERIALIZED VIEW")
      end
      descriptor = view.materialized_view || raise(UnsupportedFormatError.new("MATERIALIZED VIEW metadata is unavailable"))
      unless descriptor.source_references_complete? && descriptor.source_references.size == 1
        raise UnsupportedFormatError.new("transform requires one complete direct MATERIALIZED VIEW source reference")
      end
      source_reference = descriptor.source_references.first
      source_database = source_reference.database
      source_name = source_reference.name

      # This existing resolver enforces named/INNER UUID identity. Do not
      # replace it with a table-name lookup from SQL text.
      target = resolve_materialized_view_target(database, view_name)
      source = table(source_database, source_name)
      unless source.kind == :table && source.engine == "MergeTree"
        raise UnsupportedFormatError.new("transform source must be an ordinary MergeTree table")
      end
      source_uuid = source.uuid
      target_uuid = target.uuid
      if source_uuid == target_uuid
        raise UnsupportedFormatError.new("transform source and target must be distinct tables")
      end
      source_ddl = source.metadata_ddl || raise(UnsupportedFormatError.new("transform source DDL is unavailable"))
      target_ddl = target.metadata_ddl || raise(UnsupportedFormatError.new("transform target DDL is unavailable"))
      view_ddl = view.metadata_ddl || raise(UnsupportedFormatError.new("MATERIALIZED VIEW DDL is unavailable"))

      schema_binding = transform_target_schema_binding(
        target, rows_per_mark, compact_output, limits
      )
      destination, output_info = transform_validate_destination!(target, output_part_name)
      target.resolved_scan_parts
      target.part_candidates.each do |candidate|
        if candidate.info.overlaps?(output_info)
          raise InvalidPartError.new("transform output identity overlaps a target part candidate: #{candidate.name}")
        end
      end

      source_candidate, source_reader = source.open_typed_candidate_reader(
        source_part_name,
        source_columns,
        batch_rows
      )
      input = OfflinePartTransformInput.new(
        source_reader,
        source_reader.columns,
        source_reader.column_types,
        source_candidate.row_count,
        batch_rows
      )

      revalidate = -> do
        current_view = table(database, view_name)
        unless current_view.kind == :materialized_view && current_view.engine == "MaterializedView" &&
               current_view.uuid == view.uuid && current_view.metadata_ddl == view_ddl
          raise InvalidPartError.new("MATERIALIZED VIEW metadata changed during transform callback")
        end

        current_descriptor = current_view.materialized_view || raise(InvalidPartError.new("MATERIALIZED VIEW metadata disappeared during transform callback"))
        unless current_descriptor.source_references_complete? && current_descriptor.source_references.size == 1 &&
               current_descriptor.source_references.first.database == source_database &&
               current_descriptor.source_references.first.name == source_name
          raise InvalidPartError.new("MATERIALIZED VIEW source identity changed during transform callback")
        end

        current_target = resolve_materialized_view_target(database, view_name)
        unless current_target.uuid == target_uuid && current_target.metadata_ddl == target_ddl
          raise InvalidPartError.new("MATERIALIZED VIEW target identity changed during transform callback")
        end
        current_target.resolved_scan_parts
        current_binding = transform_target_schema_binding(
          current_target, rows_per_mark, compact_output, limits
        )
        unless current_binding.columns == schema_binding.columns
          raise InvalidPartError.new("MATERIALIZED VIEW target schema changed during transform callback")
        end

        current_source = table(source_database, source_name)
        unless current_source.kind == :table && current_source.engine == "MergeTree" &&
               current_source.uuid == source_uuid && current_source.metadata_ddl == source_ddl
          raise InvalidPartError.new("MATERIALIZED VIEW source identity changed during transform callback")
        end
        current_candidates = current_source.resolved_scan_parts
        current_selected = current_candidates.select { |candidate| candidate.name == source_part_name }
        unless current_selected.size == 1 && transform_same_candidate?(current_selected.first, source_candidate)
          raise InvalidPartError.new("selected source part changed during transform callback")
        end

        current_destination, current_info = transform_validate_destination!(current_target, output_part_name)
        unless current_destination == destination && current_info.name == output_info.name
          raise InvalidPartError.new("transform destination identity changed during callback")
        end
        current_target.part_candidates.each do |candidate|
          if candidate.info.overlaps?(current_info)
            raise InvalidPartError.new("transform output identity overlaps a target part candidate: #{candidate.name}")
          end
        end
      end

      operation = OfflineMaterializedViewPartTransform.new(input, revalidate)
      {operation, destination, schema_binding}
    end

    private def transform_validate_frame_bytes!(frame_bytes : Int, transport_limits : CompressedStreamLimits, compact_output : Bool) : Nil
      if compact_output
        unless frame_bytes > 0 && frame_bytes <= Int32::MAX
          raise ArgumentError.new("Compact frame size is outside the writer limit")
        end
      elsif frame_bytes <= 0 || frame_bytes > Int32::MAX ||
            frame_bytes > transport_limits.max_frame_decompressed_bytes
        raise ArgumentError.new("frame size is outside the compressed transport limit")
      end
      nil
    end

    private def transform_target_schema_binding(
      target : OfflineTable,
      rows_per_mark : Int32,
      compact_output : Bool,
      limits : BinaryCodecLimits,
    ) : PartSchemaBinding
      unless target.kind == :table && target.engine == "MergeTree"
        raise UnsupportedFormatError.new("transform target must be an ordinary MergeTree table")
      end
      raise UnsupportedFormatError.new("transform target cannot declare projections") unless target.projections.empty?

      columns = target.columns
      maximum_columns = compact_output ? WidePartTable::MAX_COLUMNS : WidePart::MAX_METADATA_COLUMNS
      unless columns.size >= 2 && columns.size <= maximum_columns
        raise UnsupportedFormatError.new("transform target must have a bounded key and value schema")
      end
      columns.each do |column|
        unless !column.alias_column && column.key_candidate_column
          raise UnsupportedFormatError.new("transform target columns must be plain unmodified columns")
        end
        if compact_output
          CompactPartWriter.validate_target_declaration!(column.type, limits)
        elsif !transform_output_type_supported?(column.type)
          raise UnsupportedFormatError.new("transform target column type has no admitted Wide writer owner")
        end
      end

      key = columns.first
      unless key.type == "UInt64"
        raise UnsupportedFormatError.new("transform target first column must be UInt64")
      end

      ddl = target.metadata_ddl || raise(UnsupportedFormatError.new("transform target DDL is unavailable"))
      header = /\A\s*ATTACH\s+TABLE\s+_\s+UUID\s+'([^']+)'\s*\(/i.match(ddl)
      raise UnsupportedFormatError.new("transform target DDL is not an exact persisted TABLE shape") unless header
      unless normalize_uuid(header[1]) == target.uuid && metadata_header_identity(ddl)[1] == :table
        raise InvalidPartError.new("transform target DDL identity differs from its resolved UUID")
      end

      opening = header.end(0) - 1
      closing = matching_parenthesis(ddl, opening)
      suffix = ddl.byte_slice(closing + 1, ddl.bytesize - closing - 1)
      engine = /\A\s*ENGINE\s*=\s*MergeTree\b/i.match(suffix)
      raise UnsupportedFormatError.new("transform target must use exact MergeTree engine") unless engine
      trailing = suffix.byte_slice(engine.end(0), suffix.bytesize - engine.end(0)).strip
      clauses = split_table_tail_clauses(trailing)
      raise UnsupportedFormatError.new("transform target layout suffix is not fully recognized") unless clauses

      order_clauses = clauses.not_nil!.select { |keyword, _content| keyword == "ORDER BY" }
      unless order_clauses.size == 1 && parse_simple_ascending_key_expression(order_clauses.first[1]) == key.name
        raise UnsupportedFormatError.new("transform target must have one ascending ORDER BY on its first column")
      end
      primary_clauses = clauses.not_nil!.select { |keyword, _content| keyword == "PRIMARY KEY" }
      if primary_clauses.size > 1 || primary_clauses.any? { |clause| parse_simple_ascending_key_expression(clause[1]) != key.name }
        raise UnsupportedFormatError.new("transform target PRIMARY KEY must match its single ORDER BY key")
      end
      unless clauses.not_nil!.all? { |keyword, _content| keyword == "ORDER BY" || keyword == "PRIMARY KEY" || keyword == "SETTINGS" }
        raise UnsupportedFormatError.new("transform target must be unpartitioned and have no extra layout clauses")
      end

      if settings = clauses.not_nil!.find { |keyword, _content| keyword == "SETTINGS" }
        unless transform_supported_settings?(settings[1], rows_per_mark, compact_output)
          output_format = compact_output ? "Compact" : "Wide"
          raise UnsupportedFormatError.new("transform target SETTINGS are outside the admitted #{output_format} layout subset")
        end
      elsif rows_per_mark != 8192
        raise UnsupportedFormatError.new("transform rows_per_mark must match the default target index_granularity of 8192")
      end

      binding_columns = columns.map { |column| {column.name, column.type} }
      PartSchemaBinding.new(key.name, binding_columns, compact_output ? "Compact" : "Wide")
    end

    private def transform_supported_settings?(content : String, rows_per_mark : Int32, compact_output : Bool) : Bool
      settings = Hash(String, UInt64).new
      content.split(',').each do |entry|
        match = /\A\s*(index_granularity|min_rows_for_wide_part|min_bytes_for_wide_part)\s*=\s*([0-9]+)\s*\z/i.match(entry)
        return false unless match
        name = match[1].downcase
        return false if settings.has_key?(name)
        value = match[2].to_u64?
        return false unless value
        settings[name] = value.not_nil!
      end

      return false if settings.empty?
      if granularity = settings["index_granularity"]?
        return false unless granularity == rows_per_mark.to_u64
      else
        return false unless rows_per_mark == 8192
      end

      has_min_rows = settings.has_key?("min_rows_for_wide_part")
      has_min_bytes = settings.has_key?("min_bytes_for_wide_part")
      return false if has_min_rows != has_min_bytes
      if has_min_rows && !compact_output
        return false if settings["min_rows_for_wide_part"] != 0_u64 || settings["min_bytes_for_wide_part"] != 0_u64
      end

      true
    end

    private def transform_output_type_supported?(declaration : String) : Bool
      if WidePart.json_type?(declaration)
        ObjectDocumentSchema.parse_declaration(declaration)
        return true
      end
      return true if DynamicBulkColumnDeclaration.parse(declaration)
      return true if WidePart.supports_typed_type?(declaration) || WidePart.supports_static_binary_bulk_type?(declaration)

      if declaration.starts_with?("Array(") || declaration.starts_with?("Tuple(")
        StorageColumnSchema.parse(declaration)
        return true
      end
      false
    rescue ex : ArgumentError | BoundsError | UnsupportedFormatError
      false
    end

    private def transform_validate_destination!(target : OfflineTable, part_name : String) : {String, MergeTreePartInfo}
      if part_name.empty? || part_name.bytesize > WidePartTable::MAX_PART_NAME_BYTES
        raise BoundsError.new("transform output part name is empty or exceeds limit")
      end
      unless /\Aall_(?:0|[1-9][0-9]*)_(?:0|[1-9][0-9]*)_(?:0|[1-9][0-9]*)(?:_(?:0|[1-9][0-9]*))?\z/.matches?(part_name)
        raise InvalidPartError.new("transform output name must be a canonical unpartitioned all_* part identity")
      end
      info = MergeTreePartInfo.parse(part_name)
      unless info && info.partition_id == "all" && info.name == part_name
        raise InvalidPartError.new("transform output name is not a canonical unpartitioned all_* part identity")
      end

      store_path = validate_store_directory(target.uuid)
      detached_path = File.join(store_path, "detached")
      validate_directory(detached_path, "target detached directory")
      output_path = File.join(detached_path, part_name)
      if output_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("transform output path exceeds limit")
      end
      if File.exists?(output_path) || File.symlink?(output_path)
        raise InvalidPartError.new("transform output path is already occupied")
      end
      {output_path, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot validate transform output destination")
    end

    private def transform_same_candidate?(left : OfflinePartCandidate, right : OfflinePartCandidate) : Bool
      left.name == right.name && left.path == right.path && left.row_count == right.row_count &&
        left.info.partition_id == right.info.partition_id && left.info.min_block == right.info.min_block &&
        left.info.max_block == right.info.max_block && left.info.level == right.info.level &&
        left.info.mutation == right.info.mutation && left.info.name == right.info.name
    end

    private def part_candidates_table : OfflineTable
      columns = [
        OfflineColumn.new("database", "String", false, false),
        OfflineColumn.new("table", "String", false, false),
        OfflineColumn.new("name", "String", false, false),
        OfflineColumn.new("partition_id", "String", false, false),
        OfflineColumn.new("rows", "UInt64", false, false),
      ] of OfflineColumn
      OfflineTable.new(SYSTEM_PART_CANDIDATES_TABLE_NAME, nil, "OfflineSystemPartCandidates", columns, nil, nil, self)
    end

    private def ensure_synthetic_system_available! : Nil
      if database_names.includes?(SYSTEM_DATABASE_NAME)
        raise InvalidPartError.new("physical database named system collides with the synthetic system database")
      end
    end

    private def validate_virtual_system_database!(database : OfflineDatabase) : Nil
      unless database.name == SYSTEM_DATABASE_NAME
        raise InvalidPartError.new("synthetic system database has an invalid name")
      end
      ensure_synthetic_system_available!
    end

    private def max_projected_candidates : Int32
      MAX_PART_CANDIDATES
    end

    private def ensure_candidate_capacity!(projected_candidates : Int32) : Nil
      raise BoundsError.new("system.part_candidates projected candidate count exceeds limit") if projected_candidates > max_projected_candidates
    end

    private def merge_tree_family_engine?(engine : String) : Bool
      engine.downcase.ends_with?("mergetree")
    end

    private def reject_part_candidate_overlaps!(table_name : String, candidates : Array(OfflinePartCandidate)) : Nil
      candidates.each_with_index do |left, left_index|
        right_index = left_index + 1
        while right_index < candidates.size
          right = candidates[right_index]
          if left.info.overlaps?(right.info)
            raise InvalidPartError.new("system.part_candidates refuses overlapping candidates for #{table_name}: #{left.name} and #{right.name}")
          end
          right_index += 1
        end
      end
    end

    private def table(location : DatabaseLocation, name : String) : OfflineTable
      names = list_table_names(location)
      known_names = Set(String).new
      names.each { |table_name| known_names << table_name }
      table(location, name, known_names)
    end

    private def table(
      location : DatabaseLocation,
      name : String,
      known_names : Set(String),
      projected_candidate_offset : Int32? = nil,
    ) : OfflineTable
      validate_identifier(name, "table name")
      raise InvalidPartError.new("table does not exist: #{name}") unless known_names.includes?(name)

      ddl_path = File.join(location.metadata_path, "#{encode_identifier(name)}.sql")
      ddl = read_bounded_file(ddl_path, MAX_METADATA_BYTES, "table DDL")
      uuid, columns, engine, primary_key_column, kind, projections, materialized_view = parse_table_ddl(ddl, location.name)

      part_candidates = if kind == :table && engine == "MergeTree"
                          table_path = validate_store_directory(uuid)
                          discover_part_candidates(table_path, projected_candidate_offset)
                        else
                          nil
                        end

      OfflineTable.new(name, uuid, engine, columns, part_candidates, primary_key_column, nil, kind, ddl, projections, materialized_view)
    end

    private def w88_validate_table_shape!(table : OfflineTable, role : String) : Nil
      unless table.kind == :table && table.engine == "MergeTree"
        raise UnsupportedFormatError.new("W88 #{role} must be an ordinary MergeTree table")
      end
      columns = table.columns
      unless columns.size == 2 &&
             columns[0].name == "k" && columns[0].type == "UInt64" && !columns[0].alias_column && columns[0].key_candidate_column &&
             columns[1].name == "v" && columns[1].type == "String" && !columns[1].alias_column && columns[1].key_candidate_column
        raise UnsupportedFormatError.new("W88 #{role} schema must be exactly k UInt64, v String")
      end
    end

    private def w88_validate_unpartitioned_layout!(table : OfflineTable, role : String) : Nil
      ddl = table.metadata_ddl || raise(UnsupportedFormatError.new("W88 #{role} DDL is unavailable"))
      header = /\A\s*ATTACH\s+TABLE\s+_\s+UUID\s+'[^']+'\s*\(/i.match(ddl)
      raise UnsupportedFormatError.new("W88 #{role} table DDL is not an exact persisted TABLE shape") unless header
      opening = header.end(0) - 1
      closing = matching_parenthesis(ddl, opening)
      suffix = ddl.byte_slice(closing + 1, ddl.bytesize - closing - 1)
      engine = /\A\s*ENGINE\s*=\s*MergeTree\b/i.match(suffix)
      raise UnsupportedFormatError.new("W88 #{role} must use exact MergeTree engine") unless engine
      trailing = suffix.byte_slice(engine.end(0), suffix.bytesize - engine.end(0)).strip
      clauses = split_table_tail_clauses(trailing)
      raise UnsupportedFormatError.new("W88 #{role} MergeTree layout suffix is not fully recognized") unless clauses

      order_clauses = clauses.not_nil!.select { |keyword, _content| keyword == "ORDER BY" }
      unless order_clauses.size == 1 && parse_simple_ascending_key_expression(order_clauses[0][1]) == "k"
        raise UnsupportedFormatError.new("W88 #{role} must have simple ORDER BY k")
      end
      unless clauses.not_nil!.all? { |keyword, _content| keyword == "ORDER BY" || keyword == "SETTINGS" }
        raise UnsupportedFormatError.new("W88 #{role} partitioning or extra MergeTree layout clauses are unsupported")
      end
      if setting = clauses.not_nil!.find { |keyword, _content| keyword == "SETTINGS" }
        unless w88_supported_settings?(setting[1])
          raise UnsupportedFormatError.new("W88 #{role} SETTINGS are outside the supported MergeTree subset")
        end
      end
    end

    private def w88_supported_settings?(content : String) : Bool
      settings = Hash(String, String).new
      content.split(',').each do |entry|
        match = /\A\s*(min_rows_for_wide_part|min_bytes_for_wide_part|index_granularity)\s*=\s*([0-9]+)\s*\z/i.match(entry)
        return false unless match
        name = match[1].downcase
        return false if settings.has_key?(name)
        settings[name] = match[2]
      end

      return false if settings.empty?
      return false if settings.has_key?("index_granularity") && settings["index_granularity"] != "8192"
      has_min_rows = settings.has_key?("min_rows_for_wide_part")
      has_min_bytes = settings.has_key?("min_bytes_for_wide_part")
      return false if has_min_rows != has_min_bytes
      return false if has_min_rows && (settings["min_rows_for_wide_part"] != "0" || settings["min_bytes_for_wide_part"] != "0")

      true
    end

    private def w88_validate_detached_destination!(destination : String, target : OfflineTable) : {String, MergeTreePartInfo}
      expanded_path = File.expand_path(destination)
      expanded_parent = File.dirname(expanded_path)
      unless File.basename(expanded_parent) == "detached"
        raise InvalidPartError.new("W88 output parent must be a detached directory")
      end
      raise InvalidPartError.new("W88 detached output parent is a symbolic link") if File.symlink?(expanded_parent)
      raise InvalidPartError.new("W88 detached output parent is not a directory") unless Dir.exists?(expanded_parent)
      # Resolve aliases in ancestors (for example macOS /var -> /private/var),
      # but reject a detached directory that is itself a symlink. Use only the
      # canonical path from this point onward so active-store checks cannot be
      # bypassed by an alias.
      output_parent = File.realpath(expanded_parent)
      output_path = File.join(output_parent, File.basename(expanded_path))
      if File.exists?(output_path) || File.symlink?(output_path)
        raise InvalidPartError.new("W88 output path is already occupied")
      end

      target_path = validate_store_directory(target.uuid)
      target_detached = File.join(target_path, "detached")
      store_root = File.join(@root, "store")
      if output_parent == target_path || output_parent.starts_with?(store_root + "/") && output_parent != target_detached
        raise InvalidPartError.new("W88 output must not publish into an active catalog table path")
      end

      name = File.basename(output_path)
      unless /\Aall_(?:0|[1-9][0-9]*)_(?:0|[1-9][0-9]*)_(?:0|[1-9][0-9]*)(?:_(?:0|[1-9][0-9]*))?\z/.matches?(name)
        raise InvalidPartError.new("W88 output basename must be a canonical unpartitioned all_* part identity")
      end
      info = MergeTreePartInfo.parse(name)
      unless info && info.partition_id == "all" && info.name == name
        raise InvalidPartError.new("W88 output basename is not a canonical unpartitioned all_* part identity")
      end
      {output_path, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot validate W88 detached output path")
    end

    private def parse_w88_materialized_view_identity(ddl : String) : {String, String, String, String}
      header = /\A\s*ATTACH\s+MATERIALIZED\s+VIEW\s+_\s+UUID\s+'[^']+'/i.match(ddl)
      raise UnsupportedFormatError.new("W88 view metadata must be a persisted MATERIALIZED VIEW") unless header
      tail = ddl.byte_slice(header.end(0), ddl.bytesize - header.end(0))
      identifier = "(?:`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*)"
      target_pattern = Regex.new("\\A\\s+TO\\s+(#{identifier})\\s*\\.\\s*(#{identifier})(?=\\s|\\z)", Regex::Options::IGNORE_CASE)
      target_match = target_pattern.match(tail)
      raise UnsupportedFormatError.new("W88 requires an explicit named MATERIALIZED VIEW TO target") unless target_match
      target_database = w88_identifier_value(target_match[1])
      target_name = w88_identifier_value(target_match[2])
      tail = tail.byte_slice(target_match.end(0), tail.bytesize - target_match.end(0)).lstrip

      if tail.starts_with?("(")
        closing = matching_parenthesis(tail, 0)
        tail = tail.byte_slice(closing + 1, tail.bytesize - closing - 1).lstrip
      end
      before_select, query = split_materialized_view_select(tail)
      raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW storage clauses are unsupported") unless before_select.empty?
      query_match = /\A(`k`|k)\s*,\s*(`v`|v)\s+FROM\s+((?:`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*))\s*\.\s*((?:`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*))\z/i.match(query)
      raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW SELECT must be the exact k, v identity projection") unless query_match
      unless w88_identifier_value(query_match[1]) == "k" && w88_identifier_value(query_match[2]) == "v"
        raise UnsupportedFormatError.new("W88 MATERIALIZED VIEW SELECT columns must be exactly k, v")
      end
      source_database = w88_identifier_value(query_match[3])
      source_name = w88_identifier_value(query_match[4])
      {target_database, target_name, source_database, source_name}
    end

    private def w88_identifier_value(token : String) : String
      if match = /\A`([A-Za-z_][A-Za-z0-9_]*)`\z/.match(token)
        match[1]
      elsif /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(token)
        token
      else
        raise UnsupportedFormatError.new("W88 identifier is outside the supported simple-name subset")
      end
    end

    private def w88_exact_view_columns?(columns : Array(OfflineColumn)) : Bool
      columns.size == 2 &&
        columns[0].name == "k" && columns[0].type == "UInt64" && !columns[0].alias_column && columns[0].key_candidate_column &&
        columns[1].name == "v" && columns[1].type == "String" && !columns[1].alias_column && columns[1].key_candidate_column
    end

    private def validate_database_identity!(database : OfflineDatabase, location : DatabaseLocation) : Nil
      unless location.uuid == database.uuid
        raise InvalidPartError.new("database identity changed since object creation: #{database.name}")
      end
    end

    private def validate_database_owner!(database : OfflineDatabase) : Nil
      unless database.owned_by?(self)
        raise InvalidPartError.new("database object belongs to a different offline catalog")
      end
    end

    private def resolve_database(name : String, known_names : Set(String)? = nil) : DatabaseLocation
      validate_identifier(name, "database name")
      exists = if known_names
                 known_names.includes?(name)
               else
                 database_names.includes?(name)
               end
      raise InvalidPartError.new("database does not exist: #{name}") unless exists

      metadata_root = File.join(@root, "metadata")
      ddl_path = File.join(metadata_root, "#{encode_identifier(name)}.sql")
      uuid = if File.file?(ddl_path) && !File.symlink?(ddl_path)
               parse_database_ddl(read_bounded_file(ddl_path, MAX_METADATA_BYTES, "database DDL"))
             elsif name == "default"
               link_path = File.join(metadata_root, "default")
               raise InvalidPartError.new("default metadata entry must be a symbolic link") unless File.symlink?(link_path)
               uuid_from_metadata_link(link_path)
             else
               raise InvalidPartError.new("database DDL is missing: #{name}")
             end

      store_path = validate_store_directory(uuid)
      alias_path = File.join(metadata_root, encode_identifier(name))
      if File.symlink?(alias_path)
        expected_link = "../store/#{uuid[0, 3]}/#{uuid}"
        actual_link = File.readlink(alias_path)
        raise InvalidPartError.new("database metadata symlink is not canonical: #{name}") unless actual_link == expected_link
        resolved_link = File.realpath(alias_path)
        raise InvalidPartError.new("database metadata symlink escapes the data root: #{name}") unless resolved_link == store_path && path_within_root?(resolved_link)
      elsif File.exists?(alias_path)
        raise InvalidPartError.new("database metadata alias is not a symbolic link: #{name}")
      elsif File.symlink?(alias_path)
        # A dangling link is still an invalid metadata alias.
        raise InvalidPartError.new("database metadata symlink is dangling: #{name}")
      end

      DatabaseLocation.new(name, uuid, store_path)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot resolve database metadata")
    end

    private def parse_database_ddl(ddl : String) : String
      match = /\A\s*ATTACH\s+DATABASE\s+_\s+UUID\s+'([^']+)'\s+ENGINE\s*=\s*([A-Za-z][A-Za-z0-9_]*)\s*;?\s*\z/i.match(ddl)
      raise UnsupportedFormatError.new("unsupported Atomic database DDL") unless match
      engine = match[2]
      raise UnsupportedFormatError.new("offline catalog supports Atomic databases only") unless engine.compare("Atomic", case_insensitive: true) == 0
      normalize_uuid(match[1])
    end

    private def resolve_materialized_view_target(location : DatabaseLocation, view_name : String) : OfflineTable
      view = table(location, view_name)
      unless view.kind == :materialized_view
        raise InvalidPartError.new("selected object is not a MATERIALIZED VIEW: #{view_name}")
      end
      descriptor = view.materialized_view || raise(InvalidPartError.new("MATERIALIZED VIEW target declaration is unavailable"))

      target = descriptor.target
      if target.kind == :named
        reference = target.reference || raise(InvalidPartError.new("named MATERIALIZED VIEW target reference is missing"))
        if reference.database == SYSTEM_DATABASE_NAME
          raise InvalidPartError.new("named MATERIALIZED VIEW target cannot resolve to the synthetic system database")
        end
        physical = table(reference.database, reference.name)
        unless physical.kind == :table
          raise InvalidPartError.new("named MATERIALIZED VIEW target is not a physical table")
        end
        if declared_uuid = target.uuid
          unless physical.uuid == declared_uuid
            raise InvalidPartError.new("named MATERIALIZED VIEW target UUID changed")
          end
        end
        physical
      elsif target.kind == :inner_uuid
        declared_uuid = target.uuid || raise(InvalidPartError.new("INNER UUID MATERIALIZED VIEW target UUID is missing"))
        resolve_inner_uuid_target(location, declared_uuid)
      elsif target.kind == :implicit_inner
        inner_name = ".inner_id.#{view.uuid}"
        physical = table(location, inner_name)
        unless physical.kind == :table
          raise InvalidPartError.new("implicit MATERIALIZED VIEW target is not a physical table")
        end
        physical
      else
        raise InvalidPartError.new("unknown MATERIALIZED VIEW target kind")
      end
    end

    private def resolve_inner_uuid_target(location : DatabaseLocation, uuid : String) : OfflineTable
      names = list_table_names(location)
      known_names = Set(String).new
      names.each { |name| known_names << name }

      matched_names = [] of String
      matched_kinds = [] of Symbol
      names.each do |name|
        ddl_path = File.join(location.metadata_path, "#{encode_identifier(name)}.sql")
        ddl = read_bounded_file(ddl_path, MAX_METADATA_BYTES, "table DDL")
        identity = metadata_header_identity(ddl)
        if identity[0] == uuid
          matched_names << name
          matched_kinds << identity[1]
        end
      end

      unless matched_names.size == 1
        message = matched_names.empty? ? "INNER UUID MATERIALIZED VIEW target is absent" : "INNER UUID MATERIALIZED VIEW target identity is ambiguous"
        raise InvalidPartError.new(message)
      end
      unless matched_kinds.first == :table
        raise InvalidPartError.new("INNER UUID MATERIALIZED VIEW target is not a physical table")
      end

      physical = table(location, matched_names.first, known_names)
      unless physical.kind == :table && physical.uuid == uuid
        raise InvalidPartError.new("INNER UUID MATERIALIZED VIEW target identity changed")
      end
      physical
    end

    # Read only the common metadata identity header so unrelated guarded MV
    # forms do not need full DDL parsing during UUID inventory.
    private def metadata_header_identity(ddl : String) : {String, Symbol}
      if match = /\A\s*ATTACH\s+TABLE\s+_\s+UUID\s+'([^']+)'/i.match(ddl)
        {normalize_uuid(match[1]), :table}
      elsif match = /\A\s*ATTACH\s+MATERIALIZED\s+VIEW\s+_\s+UUID\s+'([^']+)'/i.match(ddl)
        {normalize_uuid(match[1]), :materialized_view}
      else
        raise UnsupportedFormatError.new("unsupported table metadata identity header")
      end
    end

    private def parse_table_ddl(
      ddl : String,
      declaring_database : String,
    ) : {String, Array(OfflineColumn), String, String?, Symbol, Array(OfflineProjection), OfflineMaterializedView?}
      if materialized_view_header = /\A\s*ATTACH\s+MATERIALIZED\s+VIEW\s+_\s+UUID\s+'([^']+)'/i.match(ddl)
        return parse_materialized_view_ddl(ddl, materialized_view_header, declaring_database)
      end

      header = /\A\s*ATTACH\s+TABLE\s+_\s+UUID\s+'([^']+)'\s*\(/i.match(ddl)
      raise UnsupportedFormatError.new("unsupported table DDL header") unless header
      uuid = normalize_uuid(header[1])

      opening = header.end(0) - 1
      closing = matching_parenthesis(ddl, opening)
      columns_text = ddl.byte_slice(opening + 1, closing - opening - 1)
      tail = ddl.byte_slice(closing + 1, ddl.bytesize - closing - 1)
      engine_match = /\A\s*ENGINE\s*=\s*([A-Za-z][A-Za-z0-9_]*)\b/i.match(tail)
      raise UnsupportedFormatError.new("unsupported table DDL engine clause") unless engine_match
      engine = engine_match[1]
      trailing = tail.byte_slice(engine_match.end(0), tail.bytesize - engine_match.end(0)).strip
      unless trailing.empty? || supported_table_tail?(trailing)
        raise UnsupportedFormatError.new("unsupported table DDL suffix")
      end

      columns, projections = parse_column_declarations(columns_text)
      primary_key_column = engine.compare("MergeTree", case_insensitive: true) == 0 ? parse_simple_order_key(trailing, columns) : nil
      {uuid, columns, engine, primary_key_column, :table, projections, nil}
    end

    private def parse_materialized_view_ddl(
      ddl : String,
      header : Regex::MatchData,
      declaring_database : String,
    ) : {String, Array(OfflineColumn), String, String?, Symbol, Array(OfflineProjection), OfflineMaterializedView?}
      uuid = normalize_uuid(header[1])
      tail_offset = header.end(0)
      tail = ddl.byte_slice(tail_offset, ddl.bytesize - tail_offset)
      target = nil.as(OfflineMaterializedViewTarget?)

      if parsed_target = OfflineMaterializedViewTargetParser.consume(tail, declaring_database)
        target = parsed_target[1]
        tail_offset += parsed_target[0]
        tail = ddl.byte_slice(tail_offset, ddl.bytesize - tail_offset)
      end

      tail = tail.lstrip
      tail_offset = ddl.bytesize - tail.bytesize
      columns = [] of OfflineColumn
      projections = [] of OfflineProjection

      if tail.starts_with?("(")
        opening = tail_offset
        closing = matching_parenthesis(ddl, opening)
        declarations = ddl.byte_slice(opening + 1, closing - opening - 1)
        columns, projections = parse_column_declarations(declarations)
        tail_offset = closing + 1
        tail = ddl.byte_slice(tail_offset, ddl.bytesize - tail_offset).lstrip
        tail_offset = ddl.bytesize - tail.bytesize
      end

      if parsed_target = OfflineMaterializedViewTargetParser.consume(tail, declaring_database)
        raise UnsupportedFormatError.new("duplicate MATERIALIZED VIEW TO clause") if target
        target = parsed_target[1]
        tail_offset += parsed_target[0]
        tail = ddl.byte_slice(tail_offset, ddl.bytesize - tail_offset).lstrip
        tail_offset = ddl.bytesize - tail.bytesize
      end

      engine_match = /\AENGINE\s*=\s*([A-Za-z][A-Za-z0-9_]*)\b/i.match(tail)
      inner_engine = nil.as(String?)
      query = nil.as(String?)
      if engine_match
        # The storage ENGINE belongs to the MV's inner target; expose the
        # logical kind instead and never use the view UUID as a data path.
        inner_engine = String.new(engine_match[1].to_slice)
        suffix = tail.byte_slice(engine_match.end(0), tail.bytesize - engine_match.end(0))
        before_select, parsed_query = split_materialized_view_query(suffix)
        unless before_select.empty? || supported_materialized_view_storage_tail?(before_select)
          raise UnsupportedFormatError.new("unsupported MATERIALIZED VIEW storage clause")
        end
        query = parsed_query
      else
        raise UnsupportedFormatError.new("MATERIALIZED VIEW requires an inner ENGINE or TO clause") unless target
        before_select, parsed_query = split_materialized_view_query(tail)
        raise UnsupportedFormatError.new("unsupported MATERIALIZED VIEW suffix") unless before_select.empty?
        query = parsed_query
      end

      case target.try(&.kind)
      when :named
        raise UnsupportedFormatError.new("named MATERIALIZED VIEW target cannot declare an inner ENGINE") if inner_engine
      when :inner_uuid
        raise UnsupportedFormatError.new("INNER UUID MATERIALIZED VIEW target requires an inner ENGINE") unless inner_engine
      when nil
        raise UnsupportedFormatError.new("MATERIALIZED VIEW without TO requires an inner ENGINE") unless inner_engine
        target = OfflineMaterializedViewTarget.implicit_inner
      end

      parsed_query = query || raise(UnsupportedFormatError.new("MATERIALIZED VIEW SELECT definition is missing"))
      references, status, reason = OfflineMaterializedViewQueryAnalyzer.analyze(parsed_query, declaring_database)
      descriptor = OfflineMaterializedView.new(
        declaring_database: declaring_database,
        query: parsed_query,
        inner_engine: inner_engine,
        target: target || raise(UnsupportedFormatError.new("MATERIALIZED VIEW target declaration is missing")),
        source_references: references,
        source_references_status: status,
        source_references_reason: reason
      )
      {uuid, columns, "MaterializedView", nil, :materialized_view, projections, descriptor}
    end

    private def split_materialized_view_query(text : String) : {String, String}
      delimiter = find_materialized_view_query(text)
      raise UnsupportedFormatError.new("MATERIALIZED VIEW is missing AS SELECT or AS WITH") unless delimiter
      prefix = text.byte_slice(0, delimiter[0]).strip
      query = text.byte_slice(delimiter[1], text.bytesize - delimiter[1]).strip
      body = text.byte_slice(delimiter[2], text.bytesize - delimiter[2]).strip
      raise UnsupportedFormatError.new("MATERIALIZED VIEW SELECT definition is empty") if body.empty?
      if contains_unsafe_sql_control?(query)
        raise UnsupportedFormatError.new("MATERIALIZED VIEW SELECT has an unsupported statement or comment control")
      end
      {prefix, query}
    end

    # W88 retains its historical body-only, SELECT-only gate. The new
    # descriptor uses split_materialized_view_query and preserves the keyword.
    private def split_materialized_view_select(text : String) : {String, String}
      delimiter = find_materialized_view_query(text)
      raise UnsupportedFormatError.new("MATERIALIZED VIEW is missing AS SELECT") unless delimiter && delimiter[3] == :select
      prefix = text.byte_slice(0, delimiter[0]).strip
      query = text.byte_slice(delimiter[2], text.bytesize - delimiter[2]).strip
      raise UnsupportedFormatError.new("MATERIALIZED VIEW SELECT definition is empty") if query.empty?
      if contains_unsafe_sql_control?(query)
        raise UnsupportedFormatError.new("MATERIALIZED VIEW SELECT has an unsupported statement or comment control")
      end
      {prefix, query}
    end

    # Locate AS SELECT or AS WITH only at top-level and outside quoted storage metadata.
    # This keeps an identifier or setting value containing those words from
    # manufacturing the DDL boundary.
    private def find_materialized_view_query(text : String) : {Int32, Int32, Int32, Symbol}?
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = 0

      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote && index + 1 < bytes.size && bytes[index + 1] == quote
            index += 1
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("unbalanced MATERIALIZED VIEW storage suffix") if depth < 0
        elsif depth == 0
          if query = materialized_view_query_positions(bytes, index)
            return {index, query[0], query[1], query[2]}
          end
        end
        index += 1
      end

      raise UnsupportedFormatError.new("unbalanced MATERIALIZED VIEW storage suffix") unless depth == 0 && quote == 0 && !escaped
      nil
    end

    private def materialized_view_query_positions(bytes : Bytes, index : Int32) : {Int32, Int32, Symbol}?
      return nil if index > 0 && identifier_byte?(bytes[index - 1])
      return nil if index + 2 > bytes.size
      return nil unless String.new(bytes[index, 2]).compare("AS", case_insensitive: true) == 0

      cursor = index + 2
      return nil if cursor >= bytes.size || !whitespace?(bytes[cursor])
      while cursor < bytes.size && whitespace?(bytes[cursor])
        cursor += 1
      end
      if cursor + 6 <= bytes.size && String.new(bytes[cursor, 6]).compare("SELECT", case_insensitive: true) == 0
        return nil if cursor + 6 < bytes.size && identifier_byte?(bytes[cursor + 6])
        return {cursor, cursor + 6, :select}
      end

      if cursor + 4 <= bytes.size && String.new(bytes[cursor, 4]).compare("WITH", case_insensitive: true) == 0
        return nil if cursor + 4 < bytes.size && identifier_byte?(bytes[cursor + 4])
        return {cursor, cursor + 4, :with}
      end

      nil
    end

    private def contains_unsafe_sql_control?(text : String) : Bool
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = 0
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote && index + 1 < bytes.size && bytes[index + 1] == quote
            index += 1
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return true if depth < 0
        elsif byte == ';'.ord || byte == '#'.ord ||
              (byte == '-'.ord && index + 1 < bytes.size && bytes[index + 1] == '-'.ord) ||
              (byte == '/'.ord && index + 1 < bytes.size && bytes[index + 1] == '*'.ord) ||
              (byte == '*'.ord && index + 1 < bytes.size && bytes[index + 1] == '/'.ord)
          return true
        end
        index += 1
      end
      depth != 0 || quote != 0 || escaped
    end

    private def supported_table_tail?(trailing : String) : Bool
      return false unless /\A(?:ORDER\s+BY|PRIMARY\s+KEY|PARTITION\s+BY|SAMPLE\s+BY|TTL|SETTINGS|COMMENT)\b/i.matches?(trailing)

      !contains_unsupported_table_tail_control?(trailing)
    end

    # MATERIALIZED VIEW parsing needs a stronger boundary than ordinary table
    # inventory: a missing storage-clause operand immediately before `AS
    # SELECT` must not be mistaken for a valid query delimiter. Keep this
    # validator bounded to the existing stock-shaped clause subset.
    private def supported_materialized_view_storage_tail?(trailing : String) : Bool
      return true if trailing.empty?
      return false unless supported_table_tail?(trailing)

      clauses = split_table_tail_clauses(trailing)
      return false unless clauses

      previous_rank = -1
      clauses.not_nil!.each do |keyword, content|
        rank = case keyword
               when "PARTITION BY"            then 0
               when "PRIMARY KEY", "ORDER BY" then 1
               when "SAMPLE BY"               then 2
               when "TTL"                     then 3
               when "SETTINGS"                then 4
               when "COMMENT"                 then 5
               else                                return false
               end
        return false if rank < previous_rank || (rank == previous_rank && rank != 1)

        clause_supported = if keyword == "TTL"
                             !content.strip.empty? && !contains_unsafe_sql_control?(content)
                           else
                             supported_pk_suffix_clause?(keyword, content)
                           end
        return false unless clause_supported
        previous_rank = rank
      end

      true
    end

    # Extract only an exact one-column ascending ORDER BY key and optional
    # identical PRIMARY KEY. Other recognized MergeTree clauses are split at
    # top-level boundaries but never interpreted for pruning.
    private def parse_simple_order_key(trailing : String, columns : Array(OfflineColumn)) : String?
      return nil if trailing.empty?
      clauses = split_table_tail_clauses(trailing)
      return nil unless clauses

      order_clauses = clauses.not_nil!.select { |clause| clause[0] == "ORDER BY" }
      return nil unless order_clauses.size == 1
      order_column = parse_simple_ascending_key_expression(order_clauses[0][1])
      return nil unless order_column

      primary_clauses = clauses.not_nil!.select { |clause| clause[0] == "PRIMARY KEY" }
      return nil if primary_clauses.size > 1
      if primary_clause = primary_clauses.first?
        primary_column = parse_simple_ascending_key_expression(primary_clause[1])
        return nil unless primary_column == order_column
      end

      column = columns.find { |entry| entry.name == order_column }
      return nil unless column && column.type == "UInt64" && !column.alias_column && column.key_candidate_column
      return nil unless supported_pk_suffix_clauses?(clauses.not_nil!)
      order_column
    end

    private def supported_pk_suffix_clauses?(clauses : Array({String, String})) : Bool
      previous_rank = -1
      clauses.each do |keyword, content|
        rank = case keyword
               when "PARTITION BY"            then 0
               when "PRIMARY KEY", "ORDER BY" then 1
               when "SAMPLE BY"               then 2
               when "TTL"                     then 3
               when "SETTINGS"                then 4
               when "COMMENT"                 then 5
               else                                return false
               end
        # ClickHouse accepts PRIMARY KEY on either side of ORDER BY. Those
        # two clauses may therefore share a rank, but other suffix clauses
        # must remain in their canonical increasing order.
        return false if rank < previous_rank || (rank == previous_rank && rank != 1)
        return false unless supported_pk_suffix_clause?(keyword, content)
        previous_rank = rank
      end
      true
    end

    # This is intentionally a narrow suffix validator, not a general DDL
    # parser. It prevents opaque clause text from swallowing trailing tokens
    # while retaining common partitioned tables and simple SETTINGS metadata.
    private def supported_pk_suffix_clause?(keyword : String, content : String) : Bool
      case keyword
      when "PARTITION BY"
        supported_simple_partition_expression?(content)
      when "ORDER BY", "PRIMARY KEY", "SAMPLE BY"
        !!parse_simple_ascending_key_expression(content)
      when "SETTINGS"
        supported_simple_settings?(content)
      when "COMMENT"
        /\A'(?:[^']|'')*'\z/m.matches?(content)
      else
        false
      end
    end

    private def supported_simple_partition_expression?(content : String) : Bool
      identifier = "(?:`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*)"
      return true if Regex.new("\\A#{identifier}\\z").matches?(content.strip)
      return true if /\Atuple\s*\(\s*\)\z/i.matches?(content.strip)
      Regex.new("\\A[A-Za-z_][A-Za-z0-9_]*\\s*\\(\\s*#{identifier}(?:\\s*,\\s*#{identifier})*\\s*\\)\\z").matches?(content.strip)
    end

    private def supported_simple_settings?(content : String) : Bool
      setting = "[A-Za-z_][A-Za-z0-9_]*"
      value = "(?:'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"|[A-Za-z_][A-Za-z0-9_]*|[0-9]+(?:\\.[0-9]+)?)"
      Regex.new("\\A#{setting}\\s*=\\s*#{value}(?:\\s*,\\s*#{setting}\\s*=\\s*#{value})*\\z").matches?(content.strip)
    end

    private def split_table_tail_clauses(text : String) : Array({String, String})?
      clauses = Array({String, String}).new
      cursor = 0
      while cursor < text.bytesize
        while cursor < text.bytesize && whitespace?(text.to_slice[cursor])
          cursor += 1
        end
        break if cursor == text.bytesize

        match = TABLE_TAIL_CLAUSE_PATTERN.match(text.byte_slice(cursor, text.bytesize - cursor))
        return nil unless match
        keyword = match[1].gsub(/\s+/, " ").upcase
        content_start = cursor + match.end(0)
        next_clause = find_next_table_tail_clause(text, content_start)
        content_end = next_clause || text.bytesize
        content = text.byte_slice(content_start, content_end - content_start).strip
        return nil if content.empty?
        return nil if clauses.any? { |clause| clause[0] == keyword }

        clauses << {keyword, content}
        cursor = content_end
      end
      clauses
    end

    private def find_next_table_tail_clause(text : String, start : Int32) : Int32?
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = start
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif quote == '`'.ord && byte == '`'.ord && index + 1 < bytes.size && bytes[index + 1] == '`'.ord
            index += 1
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return nil if depth < 0
        elsif depth == 0 && whitespace?(byte)
          candidate = index
          while candidate < bytes.size && whitespace?(bytes[candidate])
            candidate += 1
          end
          if candidate > index && candidate < bytes.size && TABLE_TAIL_CLAUSE_PATTERN.matches?(text.byte_slice(candidate, bytes.size - candidate))
            return candidate
          end
        end
        index += 1
      end

      nil if depth != 0 || quote != 0 || escaped
    end

    private def parse_simple_ascending_key_expression(expression : String) : String?
      match = /\A(?:`([A-Za-z_][A-Za-z0-9_]*)`|([A-Za-z_][A-Za-z0-9_]*))(?:\s+ASC)?\z/i.match(expression.strip)
      return nil unless match
      match[1]? || match[2]?
    end

    # This guards the supported generated-DDL subset; it is not a general SQL
    # validator. It rejects statement/comment boundaries and a second
    # top-level ENGINE assignment without interpreting clause semantics.
    private def contains_unsupported_table_tail_control?(text : String) : Bool
      bytes = text.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = 0

      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return true if depth < 0
        elsif byte == ';'.ord || byte == '#'.ord ||
              (byte == '-'.ord && index + 1 < bytes.size && bytes[index + 1] == '-'.ord) ||
              (byte == '/'.ord && index + 1 < bytes.size && bytes[index + 1] == '*'.ord)
          return true
        elsif depth == 0 && engine_assignment_at?(text, bytes, index)
          return true
        end
        index += 1
      end

      depth != 0 || quote != 0 || escaped
    end

    private def engine_assignment_at?(text : String, bytes : Bytes, index : Int32) : Bool
      return false if index + 6 > bytes.size
      return false unless text.byte_slice(index, 6).compare("ENGINE", case_insensitive: true) == 0
      return false if index > 0 && identifier_byte?(bytes[index - 1])
      return false if index + 6 < bytes.size && identifier_byte?(bytes[index + 6])

      cursor = index + 6
      while cursor < bytes.size && whitespace?(bytes[cursor])
        cursor += 1
      end
      cursor < bytes.size && bytes[cursor] == '='.ord
    end

    private def identifier_byte?(byte : UInt8) : Bool
      byte >= 'a'.ord && byte <= 'z'.ord ||
        byte >= 'A'.ord && byte <= 'Z'.ord ||
        byte >= '0'.ord && byte <= '9'.ord ||
        byte == '_'.ord
    end

    private def parse_column_declarations(text : String) : {Array(OfflineColumn), Array(OfflineProjection)}
      definitions = split_top_level(text, "column list")
      raise UnsupportedFormatError.new("table DDL has no columns") if definitions.empty?
      raise BoundsError.new("table column count exceeds limit") if definitions.size > 4_096

      columns = Array(OfflineColumn).new(definitions.size)
      projections = Array(OfflineProjection).new
      seen_columns = Set(String).new
      seen_projections = Set(String).new
      definitions.each do |definition|
        if /\APROJECTION\b/i.matches?(definition.strip)
          projection = parse_projection_definition(definition)
          raise UnsupportedFormatError.new("duplicate projection name: #{projection.name}") if seen_projections.includes?(projection.name)
          seen_projections << projection.name
          projections << projection
        else
          name, type, alias_column, key_candidate_column = parse_column_definition(definition)
          raise UnsupportedFormatError.new("duplicate table column name: #{name}") if seen_columns.includes?(name)
          seen_columns << name
          columns << OfflineColumn.new(name, type, alias_column, key_candidate_column)
        end
      end
      raise UnsupportedFormatError.new("table DDL has no columns") if columns.empty?
      {columns, projections}
    end

    private def parse_projection_definition(definition : String) : OfflineProjection
      source = definition.strip
      header = /\APROJECTION\s+(`(?:\\.|[^`])+`|[A-Za-z_][A-Za-z0-9_]*)\s*\(/i.match(source)
      raise UnsupportedFormatError.new("unsupported projection declaration") unless header
      name = parse_projection_name(header[1])
      opening = header.end(0) - 1
      closing = matching_parenthesis(source, opening)
      unless source.byte_slice(closing + 1, source.bytesize - closing - 1).strip.empty?
        raise UnsupportedFormatError.new("unsupported projection declaration suffix")
      end

      body = source.byte_slice(opening + 1, closing - opening - 1).strip
      select_match = /\ASELECT\b/i.match(body)
      raise UnsupportedFormatError.new("projection definition must be a SELECT") unless select_match
      raise UnsupportedFormatError.new("projection SELECT definition is empty") if body.byte_slice(select_match.end(0), body.bytesize - select_match.end(0)).strip.empty?
      if contains_unsafe_sql_control?(body)
        raise UnsupportedFormatError.new("projection definition contains an unsupported statement or comment control")
      end
      OfflineProjection.new(name, body)
    end

    private def parse_projection_name(token : String) : String
      if token.starts_with?("`")
        bytes = token.to_slice
        index = 1
        closed = false
        name = String.build do |io|
          while index < bytes.size
            byte = bytes[index]
            if byte == '\\'.ord
              index += 1
              raise UnsupportedFormatError.new("unterminated escaped projection name") if index >= bytes.size
              io.write_byte(bytes[index])
            elsif byte == '`'.ord
              closed = true
              index += 1
              break
            else
              io.write_byte(byte)
            end
            index += 1
          end
        end
        raise UnsupportedFormatError.new("unterminated projection name") unless closed && index == bytes.size
        validate_identifier(name, "projection name")
        name
      else
        validate_identifier(token, "projection name")
        token
      end
    end

    private def parse_column_definition(definition : String) : {String, String, Bool, Bool}
      source = definition.strip
      bytes = source.to_slice
      raise UnsupportedFormatError.new("unsupported table column definition") if bytes.empty? || bytes[0] != '`'.ord

      index = 1
      closed = false
      name = String.build do |io|
        while index < bytes.size
          byte = bytes[index]
          if byte == '\\'.ord
            index += 1
            raise UnsupportedFormatError.new("unterminated escaped column name") if index >= bytes.size
            io.write_byte(bytes[index])
          elsif byte == '`'.ord
            closed = true
            index += 1
            break
          else
            io.write_byte(byte)
          end
          index += 1
        end
      end
      raise UnsupportedFormatError.new("unterminated column name") unless closed
      raise UnsupportedFormatError.new("column name is empty or exceeds limit") if name.empty? || name.bytesize > MAX_IDENTIFIER_BYTES
      raise UnsupportedFormatError.new("invalid UTF-8 table column name") unless name.valid_encoding?

      while index < bytes.size && whitespace?(bytes[index])
        index += 1
      end
      raise UnsupportedFormatError.new("column type is missing") if index >= bytes.size

      type_start = index
      type_end = find_column_type_end(source, type_start)
      type = source.byte_slice(type_start, type_end - type_start).strip
      raise UnsupportedFormatError.new("column type is empty") if type.empty?

      modifier = source.byte_slice(type_end, source.bytesize - type_end).strip
      unless modifier.empty? || column_modifier?(modifier)
        raise UnsupportedFormatError.new("unsupported table column modifier")
      end

      {name, type, /\AALIAS\b/i.matches?(modifier), modifier.empty?}
    end

    private def find_column_type_end(source : String, start : Int32) : Int32
      bytes = source.to_slice
      depth = 0
      quote = 0_u8
      escaped = false
      index = start
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("unbalanced column type") if depth < 0
        elsif depth == 0 && whitespace?(byte)
          cursor = index
          while cursor < bytes.size && whitespace?(bytes[cursor])
            cursor += 1
          end
          if cursor == bytes.size
            return index
          elsif column_modifier?(source.byte_slice(cursor).strip)
            return index
          else
            raise UnsupportedFormatError.new("unsupported whitespace in column type")
          end
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unbalanced column type") unless depth == 0 && quote == 0
      bytes.size
    end

    private def column_modifier?(text : String) : Bool
      /\A(?:DEFAULT|MATERIALIZED|ALIAS|CODEC|COMMENT|TTL)\b/i.matches?(text)
    end

    private def split_top_level(text : String, context : String) : Array(String)
      bytes = text.to_slice
      values = Array(String).new
      depth = 0
      quote = 0_u8
      escaped = false
      start = 0
      index = 0
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("unbalanced #{context}") if depth < 0
        elsif byte == ','.ord && depth == 0
          values << text.byte_slice(start, index - start).strip
          start = index + 1
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unbalanced #{context}") unless depth == 0 && quote == 0 && !escaped
      final = text.byte_slice(start, bytes.size - start).strip
      raise UnsupportedFormatError.new("empty #{context} entry") if final.empty? || values.any?(&.empty?)
      values << final
      values
    end

    private def matching_parenthesis(text : String, opening : Int32) : Int32
      bytes = text.to_slice
      depth = 1
      quote = 0_u8
      escaped = false
      index = opening + 1
      while index < bytes.size
        byte = bytes[index]
        if quote != 0
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif byte == quote
            quote = 0_u8
          end
        elsif byte == '\''.ord || byte == '"'.ord || byte == '`'.ord
          quote = byte
        elsif byte == '('.ord
          depth += 1
        elsif byte == ')'.ord
          depth -= 1
          return index if depth == 0
        end
        index += 1
      end
      raise UnsupportedFormatError.new("unterminated table column list")
    end

    private def discover_part_candidates(table_path : String, projected_candidate_offset : Int32? = nil) : Array(OfflinePartCandidate)
      children = bounded_children(table_path, WidePartTable::MAX_PARTS + 2_048, "table data entries")
      candidates = Array(OfflinePartCandidate).new
      total_rows = 0_u64

      children.each do |name|
        path = File.join(table_path, name)
        raise InvalidPartError.new("symbolic link in table data directory: #{name}") if File.symlink?(path)

        if name == "detached" || name.starts_with?("tmp") || name.starts_with?("delete_tmp_")
          raise InvalidPartError.new("detached or temporary entry is not a directory: #{name}") unless Dir.exists?(path)
          next
        end

        info = MergeTreePartInfo.parse(name)
        unless info
          if MergeTreePartInfo.part_like?(name) || Dir.exists?(path) && name.split('_').size >= 3
            raise InvalidPartError.new("malformed part-like directory name: #{name}")
          end
          next
        end

        raise InvalidPartError.new("part candidate is not a physical directory: #{name}") unless Dir.exists?(path)
        raise UnsupportedFormatError.new("patch parts are not supported: #{name}") if info.patch?
        raise BoundsError.new("part count exceeds limit") if candidates.size >= WidePartTable::MAX_PARTS
        if offset = projected_candidate_offset
          ensure_candidate_capacity!(offset + candidates.size + 1)
        end

        count_path = File.join(path, "count.txt")
        row_count = parse_row_count(read_bounded_file(count_path, MAX_COUNT_BYTES, "part row count"))
        raise BoundsError.new("table candidate row count exceeds limit") if row_count > WidePartTable::MAX_TOTAL_ROWS - total_rows
        total_rows += row_count
        candidates << OfflinePartCandidate.new(name, path, info, row_count)
      end

      candidates.sort_by!(&.name)
      candidates
    end

    private def parse_row_count(text : String) : UInt64
      value = text
      value = value.byte_slice(0, value.bytesize - 1) if value.ends_with?('\n')
      raise CorruptPartError.new("invalid part row count") if value.empty? || value.bytesize > 20

      result = 0_u64
      value.each_byte do |byte|
        raise CorruptPartError.new("invalid part row count") unless byte >= '0'.ord && byte <= '9'.ord
        digit = (byte - '0'.ord).to_u64
        raise CorruptPartError.new("part row count overflows UInt64") if result > (UInt64::MAX - digit) // 10
        result = result * 10 + digit
      end
      raise CorruptPartError.new("physical part has zero rows") if result == 0
      result
    end

    private def parse_default_metadata_link(path : String) : String
      target = File.readlink(path)
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match(target)
      raise InvalidPartError.new("default metadata symlink target is not canonical") unless match

      uuid = normalize_uuid(match[2])
      raise InvalidPartError.new("default metadata symlink prefix does not match UUID") unless match[1] == uuid[0, 3]
      expected = File.join(@root, "store", uuid[0, 3], uuid)
      resolved = File.realpath(path)
      raise InvalidPartError.new("default metadata symlink escapes the data root") unless resolved == expected && path_within_root?(resolved)
      uuid
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot resolve default metadata symlink")
    end

    private def uuid_from_metadata_link(path : String) : String
      parse_default_metadata_link(path)
    end

    private def validate_store_directory(uuid : String) : String
      normalized = normalize_uuid(uuid)
      prefix_path = File.join(@root, "store", normalized[0, 3])
      validate_directory(prefix_path, "UUID store prefix")
      store_path = File.join(prefix_path, normalized)
      validate_directory(store_path, "UUID store directory")
      store_path
    end

    private def validate_directory(path : String, context : String) : Nil
      raise InvalidPartError.new("#{context} is a symbolic link") if File.symlink?(path)
      raise InvalidPartError.new("#{context} is not a directory") unless Dir.exists?(path)
      resolved = File.realpath(path)
      raise InvalidPartError.new("#{context} escapes the offline data root") unless resolved == path && path_within_root?(resolved)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot validate #{context}")
    end

    private def bounded_children(path : String, limit : Int32, context : String) : Array(String)
      children = Array(String).new
      Dir.each_child(path) do |name|
        raise BoundsError.new("#{context} exceed limit") if children.size >= limit
        children << name
      end
      children.sort!
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot enumerate #{context}")
    end

    private def read_bounded_file(path : String, limit : Int32, context : String) : String
      raise InvalidPartError.new("#{context} is a symbolic link") if File.symlink?(path)
      raise InvalidPartError.new("#{context} is not a regular file") unless File.file?(path)

      String.build do |output|
        File.open(path, "r") do |input|
          buffer = Bytes.new(8_192)
          total = 0
          while (read = input.read(buffer)) > 0
            raise BoundsError.new("#{context} exceeds size limit") if read > limit - total
            output.write(buffer[0, read])
            total += read
          end
        end
      end
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read #{context}")
    end

    private def decode_identifier(encoded : String, context : String) : String
      raise BoundsError.new("#{context} exceeds size limit") if encoded.bytesize > MAX_IDENTIFIER_BYTES * 3
      source = encoded.to_slice
      decoded = Bytes.new(source.size)
      input = 0
      output = 0
      while input < source.size
        byte = source[input]
        if byte == '%'.ord
          raise InvalidPartError.new("malformed escaped byte in #{context}") if input + 2 >= source.size
          high = hex_value(source[input + 1])
          low = hex_value(source[input + 2])
          raise InvalidPartError.new("malformed escaped byte in #{context}") unless high && low
          decoded[output] = (high * 16 + low).to_u8
          input += 3
        else
          raise InvalidPartError.new("noncanonical raw byte in #{context}") unless ascii_word_byte?(byte)
          decoded[output] = byte
          input += 1
        end
        output += 1
      end

      name = String.new(decoded[0, output])
      raise InvalidPartError.new("invalid UTF-8 in #{context}") unless name.valid_encoding?
      validate_identifier(name, context)
      raise InvalidPartError.new("noncanonical escaped filename in #{context}") unless encode_identifier(name) == encoded
      name
    end

    private def encode_identifier(name : String) : String
      String.build do |io|
        name.each_byte do |byte|
          if ascii_word_byte?(byte)
            io.write_byte(byte)
          else
            io << '%' << byte.to_s(16).upcase.rjust(2, '0')
          end
        end
      end
    end

    private def validate_identifier(name : String, context : String) : Nil
      raise InvalidPartError.new("empty #{context}") if name.empty?
      raise BoundsError.new("#{context} exceeds size limit") if name.bytesize > MAX_IDENTIFIER_BYTES
      raise InvalidPartError.new("invalid UTF-8 in #{context}") unless name.valid_encoding?
    end

    private def ascii_word_byte?(byte : UInt8) : Bool
      byte >= 'a'.ord && byte <= 'z'.ord ||
        byte >= 'A'.ord && byte <= 'Z'.ord ||
        byte >= '0'.ord && byte <= '9'.ord ||
        byte == '_'.ord
    end

    private def hex_value(byte : UInt8) : UInt8?
      if byte >= '0'.ord && byte <= '9'.ord
        (byte - '0'.ord).to_u8
      elsif byte >= 'A'.ord && byte <= 'F'.ord
        (byte - 'A'.ord + 10).to_u8
      else
        nil
      end
    end

    private def normalize_uuid(text : String) : String
      unless /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.matches?(text)
        raise UnsupportedFormatError.new("invalid UUID in ClickHouse metadata")
      end
      text.downcase
    end

    private def path_within_root?(path : String) : Bool
      path == @root || path.starts_with?(@root + "/")
    end

    private def canonical_root(path : String) : String
      File.realpath(path)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read offline data root")
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\r'.ord || byte == '\n'.ord
    end
  end
end

require "./offline_catalog/database_location"
