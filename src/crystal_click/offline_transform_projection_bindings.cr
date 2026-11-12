module CrystalClick
  # DDL-derived child schemas for one caller-run transform. The catalog builds
  # this before invoking caller code, then binds the supplied immutable child
  # owners after the full scan and exact metadata revalidation.
  private class OfflineTransformProjectionBindings
    private alias ProjectionSchema = NamedTuple(binding: PartSchemaBinding, aggregate_count: Bool)

    @schema_by_name : Hash(String, ProjectionSchema)

    private def initialize(target : OfflineTable, parent_target : String)
      projections = target.projections
      if projections.size > WidePartWriter::MAX_PROJECTIONS
        raise UnsupportedFormatError.new("transform target projection count exceeds the writer limit")
      end

      target_columns = target.columns
      @schema_by_name = Hash(String, ProjectionSchema).new(initial_capacity: projections.size)
      projections.each do |projection|
        projection_name = projection.name
        max_name_bytes = WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
        unless projection_name.bytesize > 0 && projection_name.bytesize <= max_name_bytes &&
               /\A[A-Za-z0-9_]+\z/.matches?(projection_name)
          raise UnsupportedFormatError.new("transform target projection name is outside the writer limit")
        end
        child_path = File.join(parent_target, "#{projection_name}.proj")
        if child_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
          raise UnsupportedFormatError.new("transform target projection child path exceeds the writer limit")
        end

        if @schema_by_name.has_key?(projection_name)
          raise UnsupportedFormatError.new("transform target projection names must be unique")
        end
        @schema_by_name[projection_name] = parse_schema(projection.definition.strip, target_columns)
      end
    end

    def self.from_target(target : OfflineTable, parent_target : String) : OfflineTransformProjectionBindings
      new(target, parent_target)
    end

    # Validate exact name membership and attach each declaration's schema,
    # preserving callback order for the existing writer roster.
    def bind(
      projections : Indexable(WidePartProjection | CompactPartProjection),
      parent_rows : UInt64,
    ) : Array(WidePartProjection | CompactPartProjection)
      unless projections.size == @schema_by_name.size
        raise UnsupportedFormatError.new("transform projection output roster does not match target DDL")
      end

      names = Set(String).new
      projections.each do |projection|
        unless names.add?(projection.name)
          raise UnsupportedFormatError.new("transform projection output names must be unique")
        end
      end

      retained = Array(WidePartProjection | CompactPartProjection).new(projections.size)
      projections.each do |projection|
        schema = @schema_by_name[projection.name]?
        unless schema
          raise UnsupportedFormatError.new("transform projection output roster does not match target DDL")
        end
        binding = schema[:binding]
        unless projection.key_name == binding.key_name
          raise UnsupportedFormatError.new("transform projection output key does not match target schema")
        end
        count_child = projection.is_a?(WidePartProjection) && !projection.count_total.nil?
        if schema[:aggregate_count]
          unless count_child
            raise UnsupportedFormatError.new("transform count projection requires a Wide count child")
          end
        else
          if count_child
            raise UnsupportedFormatError.new("transform plain projection requires a non-aggregate child")
          end
          unless projection.row_count == parent_rows
            raise UnsupportedFormatError.new("transform projection output row count does not match parent row count")
          end
        end

        retained << projection.with_schema_binding(binding)
      end
      retained
    end

    private def parse_schema(definition : String, target_columns : Array(OfflineColumn)) : ProjectionSchema
      if grouped = /\ASELECT\s+([\s\S]+?)\s+GROUP\s+BY\s+([\s\S]+)\z/i.match(definition)
        binding = parse_count_schema(grouped[1], grouped[2], target_columns)
        return {binding: binding, aggregate_count: true}
      end

      plain = /\ASELECT\b([\s\S]*?)\s+ORDER\s+BY\s+([\s\S]+)\z/i.match(definition)
      unless plain
        raise UnsupportedFormatError.new("transform projection must be a simple ordered SELECT or a GROUP BY with count()")
      end
      selected = plain[1].split(',')
      if selected.size < 2
        raise UnsupportedFormatError.new("transform projection SELECT must list the target UInt64 key followed by value columns")
      end
      selected_columns = selected.map { |token| plain_target_column(token, target_columns) }
      unless selected_columns.map(&.name).to_set.size == selected_columns.size
        raise UnsupportedFormatError.new("transform projection SELECT columns must be unique")
      end

      key = selected_columns.first
      order_key = parse_identifier(plain[2].strip.sub(/\s+ASC\z/i, ""))
      unless key.type == "UInt64" && order_key == key.name
        raise UnsupportedFormatError.new("transform projection ORDER BY must match its first selected UInt64 key")
      end
      columns = selected_columns.map { |column| {column.name, column.type} }
      {binding: PartSchemaBinding.new(key.name, columns, "projection"), aggregate_count: false}
    end

    private def parse_count_schema(select_list : String, group_key : String, target_columns : Array(OfflineColumn)) : PartSchemaBinding
      key = plain_target_column(group_key, target_columns)
      unless key.type == "UInt64"
        raise UnsupportedFormatError.new("transform count projection GROUP BY requires one plain UInt64 key")
      end

      selected = select_list.split(',')
      if selected.size == 2
        key_index = selected.index { |token| parse_identifier(token) == key.name }
        if key_index
          selected.delete_at(key_index)
        end
      end
      unless selected.size == 1 && (count = /\Acount\s*\(\s*\)(?:\s+(?i:AS)\s+([\s\S]+))?\z/.match(selected.first.strip))
        raise UnsupportedFormatError.new("transform count projection SELECT must contain count() and optionally its group key")
      end
      if alias_token = count[1]?
        alias_name = parse_identifier(alias_token)
        unless alias_name && alias_name != key.name && alias_name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES
          raise UnsupportedFormatError.new("transform count projection alias must be a distinct bounded ASCII identifier")
        end
      end

      # ClickHouse stores the mergeable-state header: the GROUP BY key is
      # first and the aggregate uses its expression name, even with an alias.
      columns = [{key.name, key.type}, {"count()", WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME}]
      PartSchemaBinding.new(key.name, columns, "projection")
    end

    private def plain_target_column(token : String, target_columns : Array(OfflineColumn)) : OfflineColumn
      name = parse_identifier(token)
      unless name
        raise UnsupportedFormatError.new("transform projection SELECT supports only plain named target columns")
      end
      column = target_columns.find { |candidate| candidate.name == name }
      unless column && !column.alias_column && column.key_candidate_column
        raise UnsupportedFormatError.new("transform projection SELECT must reference plain target columns")
      end
      column
    end

    private def parse_identifier(expression : String) : String?
      match = /\A(?:`([A-Za-z_][A-Za-z0-9_]*)`|([A-Za-z_][A-Za-z0-9_]*))\z/.match(expression.strip)
      return nil unless match
      match[1]? || match[2]?
    end
  end
end
