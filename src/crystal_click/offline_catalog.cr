module CrystalClick
  # The column name and declared type parsed from ClickHouse table DDL.
  struct OfflineColumn
    getter name : String
    getter type : String

    def initialize(@name : String, @type : String)
    end
  end

  # A physical on-disk part directory. This identity does not imply that the
  # ClickHouse server considers the part active or otherwise authoritative.
  struct OfflinePartCandidate
    getter name : String
    getter path : String
    getter info : MergeTreePartInfo
    getter row_count : UInt64

    def initialize(@name : String, @path : String, @info : MergeTreePartInfo, @row_count : UInt64)
    end
  end

  # Read-only view of one table's parsed DDL and physical part candidates.
  class OfflineTable
    getter name : String
    getter uuid : String
    getter engine : String

    @columns : Array(OfflineColumn)
    @part_candidates : Array(OfflinePartCandidate)?

    def initialize(
      @name : String,
      @uuid : String,
      @engine : String,
      @columns : Array(OfflineColumn),
      @part_candidates : Array(OfflinePartCandidate)?,
    )
    end

    def columns : Array(OfflineColumn)
      @columns.dup
    end

    def part_candidates : Array(OfflinePartCandidate)
      candidates = @part_candidates
      raise UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only") unless candidates
      candidates.dup
    end

    # Scan table-declared UInt64 columns through the existing Wide-part reader.
    # The callback receives borrowed slices valid only until it returns.
    def scan_uint64(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        column = @columns.find { |entry| entry.name == column_name }
        raise UnsupportedFormatError.new("selected column is not declared by table DDL") unless column
        raise UnsupportedFormatError.new("selected table column is not UInt64") unless column.type == "UInt64"
      end

      candidates = @part_candidates || raise(UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only"))
      return nil if candidates.empty?

      paths = candidates.map(&.path)
      reader = WidePartTable.open_selected(paths, columns)
      reader.scan(batch_rows: batch_rows, &block)
    end

    # Scan selected exact primitive numeric columns. The type declared by the
    # table DDL must exactly match each selected part's columns.txt type.
    def scan_numeric(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        column = @columns.find { |entry| entry.name == column_name }
        raise UnsupportedFormatError.new("selected column is not declared by table DDL") unless column
        raise UnsupportedFormatError.new("selected table column is not an exact primitive numeric type") unless WidePart.supports_numeric_type?(column.type)
      end

      candidates = @part_candidates || raise(UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only"))
      return nil if candidates.empty?

      reader = WidePartTable.open_selected_numeric(candidates.map(&.path), columns)
      reader.column_types.each do |column_name, part_type|
        ddl_column = @columns.find { |entry| entry.name == column_name } || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        unless ddl_column.type == part_type
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader.scan_numeric(batch_rows: batch_rows, &block)
    end

    # Scan exact String, primitive numeric, and Nullable(primitive numeric)
    # columns. Selected part types must exactly match this table's DDL before
    # the first callback is allowed to run.
    def scan_typed(
      columns : Array(String),
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      &block : WidePartTableBatch -> Nil
    ) : Nil
      raise UnsupportedFormatError.new("offline scan supports exact MergeTree engine only") unless @engine == "MergeTree"
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS

      selected = Set(String).new
      expected_sources = Hash(String, {String, String, String, Bool}).new
      columns.each do |column_name|
        raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
        selected << column_name

        source_name, source_type, selected_type, json_path = resolve_typed_ddl_selection(column_name)
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.supports_typed_type?(selected_type)
        expected_sources[column_name] = {source_name, source_type, selected_type, json_path}
      end

      candidates = @part_candidates || raise(UnsupportedFormatError.new("offline part inventory supports exact MergeTree engine only"))
      return nil if candidates.empty?

      reader = WidePartTable.open_selected_typed(candidates.map(&.path), columns)
      reader.column_sources.each do |column_name, part_source_name, part_source_type|
        ddl_source = expected_sources[column_name]? || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        if ddl_source[3]
          unless part_source_name == ddl_source[0] && part_source_type == ddl_source[1]
            raise UnsupportedFormatError.new("table DDL and selected JSON schema differ")
          end
        elsif part_source_name != ddl_source[0] || part_source_type != ddl_source[1]
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader.column_types.each do |column_name, part_type|
        ddl_source = expected_sources[column_name]? || raise(CorruptPartError.new("selected column disappeared from table DDL"))
        unless ddl_source[2] == part_type
          raise UnsupportedFormatError.new("table DDL and selected part column types differ")
        end
      end
      reader.scan_typed(batch_rows: batch_rows, &block)
    end

    private def resolve_typed_ddl_selection(column_name : String) : {String, String, String, Bool}
      exact = @columns.find { |entry| entry.name == column_name }
      virtual = Array({String, String, String}).new
      @columns.each do |source|
        next unless WidePart.json_type?(source.type)
        prefix = "#{source.name}."
        next unless column_name.starts_with?(prefix)
        path = column_name.byte_slice(prefix.bytesize, column_name.bytesize - prefix.bytesize)
        if path_type = WidePart.json_typed_path_type(source.type, path)
          virtual << {source.name, source.type, path_type}
        end
      end

      if exact && !virtual.empty?
        raise UnsupportedFormatError.new("selected column is ambiguous between a literal dotted column and a JSON typed path")
      end
      if selected = exact
        raise UnsupportedFormatError.new("selected table column type is unsupported") unless WidePart.supports_typed_type?(selected.type)
        return {selected.name, selected.type, selected.type, false}
      end
      raise UnsupportedFormatError.new("selected column is not declared by table DDL") if virtual.empty?
      raise UnsupportedFormatError.new("selected JSON typed path is ambiguous") unless virtual.size == 1
      {virtual[0][0], virtual[0][1], virtual[0][2], true}
    end
  end

  # Offline reader for the bounded ClickHouse 26.7 Atomic metadata layout.
  # It reads local files only and does not emulate system.* tables or server
  # lifecycle state.
  class OfflineCatalog
    MAX_METADATA_ENTRIES =    10_000
    MAX_METADATA_BYTES   = 1_048_576
    MAX_IDENTIFIER_BYTES =     4_096
    MAX_COUNT_BYTES      =        32

    private struct DatabaseLocation
      getter uuid : String
      getter metadata_path : String

      def initialize(@uuid : String, @metadata_path : String)
      end
    end

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

    def table_names(database : String) : Array(String)
      location = resolve_database(database)
      list_table_names(location)
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
      location = resolve_database(database)
      names = list_table_names(location)
      raise InvalidPartError.new("table does not exist: #{name}") unless names.includes?(name)

      ddl_path = File.join(location.metadata_path, "#{encode_identifier(name)}.sql")
      ddl = read_bounded_file(ddl_path, MAX_METADATA_BYTES, "table DDL")
      uuid, columns, engine = parse_table_ddl(ddl)

      part_candidates = if engine == "MergeTree"
                          table_path = validate_store_directory(uuid)
                          discover_part_candidates(table_path)
                        else
                          nil
                        end

      OfflineTable.new(name, uuid, engine, columns, part_candidates)
    end

    private def resolve_database(name : String) : DatabaseLocation
      validate_identifier(name, "database name")
      names = database_names
      raise InvalidPartError.new("database does not exist: #{name}") unless names.includes?(name)

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

      DatabaseLocation.new(uuid, store_path)
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

    private def parse_table_ddl(ddl : String) : {String, Array(OfflineColumn), String}
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

      columns = parse_columns(columns_text)
      {uuid, columns, engine}
    end

    private def supported_table_tail?(trailing : String) : Bool
      return false unless /\A(?:ORDER\s+BY|PRIMARY\s+KEY|PARTITION\s+BY|SAMPLE\s+BY|TTL|SETTINGS|COMMENT)\b/i.matches?(trailing)

      !contains_unsupported_table_tail_control?(trailing)
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

    private def parse_columns(text : String) : Array(OfflineColumn)
      definitions = split_top_level(text, "column list")
      raise UnsupportedFormatError.new("table DDL has no columns") if definitions.empty?
      raise BoundsError.new("table column count exceeds limit") if definitions.size > 4_096

      columns = Array(OfflineColumn).new(definitions.size)
      seen = Set(String).new
      definitions.each do |definition|
        name, type = parse_column_definition(definition)
        raise UnsupportedFormatError.new("duplicate table column name: #{name}") if seen.includes?(name)
        seen << name
        columns << OfflineColumn.new(name, type)
      end
      columns
    end

    private def parse_column_definition(definition : String) : {String, String}
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

      {name, type}
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

    private def discover_part_candidates(table_path : String) : Array(OfflinePartCandidate)
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
