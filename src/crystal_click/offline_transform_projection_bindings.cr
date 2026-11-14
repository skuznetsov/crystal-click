module CrystalClick
  # DDL-derived child schemas for one caller-run transform. The catalog builds
  # this before invoking caller code, then binds the supplied immutable child
  # owners after the full scan and exact metadata revalidation.
  private class OfflineTransformProjectionBindings
    private alias ProjectionSchema = NamedTuple(
      binding: PartSchemaBinding,
      aggregate: Bool,
      aggregate_count: Bool,
    )

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
        key_names_match = if wide = projection.as?(WidePartProjection)
                            wide.key_names == binding.key_names
                          else
                            projection.key_name == binding.key_name
                          end
        unless key_names_match
          raise UnsupportedFormatError.new("transform projection output key does not match target schema")
        end
        aggregate_child = if wide = projection.as?(WidePartProjection)
                            wide.aggregate_projection?
                          elsif compact = projection.as?(CompactPartProjection)
                            compact.aggregate_projection?
                          else
                            false
                          end
        count_child = !projection.count_total.nil?
        if compact = projection.as?(CompactPartProjection)
          if aggregate_child
            bound_columns = [{compact.key_name, "UInt64"}] of Tuple(String, String)
            compact.aggregate_columns.each do |aggregate|
              descriptor = aggregate.descriptor
              bound_columns << {descriptor.column_name, descriptor.type_name}
            end
            binding.validate_compact!(bound_columns)

            bound_keys = binding.key_names
            unless bound_keys.size == 1 && bound_keys[0] == compact.key_name
              raise UnsupportedFormatError.new("transform Compact aggregate child requires one UInt64 GROUP BY key")
            end
            if !count_child && compact.row_count > parent_rows
              raise UnsupportedFormatError.new("transform Compact aggregate group count exceeds the parent row count")
            end
          end
        end
        if schema[:aggregate_count]
          unless count_child
            raise UnsupportedFormatError.new("transform count projection requires a Wide count child or an exact Compact Count child")
          end
        elsif schema[:aggregate]
          unless aggregate_child
            raise UnsupportedFormatError.new("transform aggregate projection requires a caller-computed aggregate child")
          end
          if count_child
            raise UnsupportedFormatError.new("transform aggregate projection roster does not match target DDL")
          end
        else
          if aggregate_child || count_child
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
        binding, aggregate_count = parse_aggregate_schema(grouped[1], grouped[2], target_columns)
        return {
          binding:         binding,
          aggregate:       true,
          aggregate_count: aggregate_count,
        }
      end

      plain = /\ASELECT\b([\s\S]*?)\s+ORDER\s+BY\s+([\s\S]+)\z/i.match(definition)
      unless plain
        raise UnsupportedFormatError.new("transform projection must be a simple ordered SELECT or an admitted aggregate GROUP BY")
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
      {
        binding:         PartSchemaBinding.new(key.name, columns, "projection"),
        aggregate:       false,
        aggregate_count: false,
      }
    end

    private def parse_aggregate_schema(
      select_list : String,
      group_keys_sql : String,
      target_columns : Array(OfflineColumn),
    ) : Tuple(PartSchemaBinding, Bool)
      group_keys = group_keys_sql.split(',').map { |token| plain_target_column(token, target_columns) }
      unless group_keys.size == 1 || group_keys.size == 2
        raise UnsupportedFormatError.new("transform aggregate projection GROUP BY requires one or two plain UInt64 keys")
      end
      unless group_keys.map(&.name).to_set.size == group_keys.size
        raise UnsupportedFormatError.new("transform aggregate projection GROUP BY keys must be distinct")
      end
      unless group_keys.all? { |key| key.type == "UInt64" }
        message = group_keys.size == 1 ? "transform aggregate projection GROUP BY requires one plain UInt64 key" : "transform aggregate projection GROUP BY requires two plain UInt64 keys"
        raise UnsupportedFormatError.new(message)
      end

      selected = select_list.split(',')
      key_names = group_keys.map(&.name)
      columns = group_keys.map { |key| {key.name, key.type} }
      aliases = Array(String).new
      aggregate_arguments = Set(String).new
      aggregate_functions = Set(WidePartProjectionAggregateDescriptor::Function).new
      count_seen = false
      selected_keys = Set(String).new
      selected.each do |raw_token|
        token = raw_token.strip
        if selected_key = parse_identifier(token)
          unless key_names.includes?(selected_key) && selected_keys.add?(selected_key)
            message = if key_names.size == 1
                        "transform aggregate projection SELECT must contain only its GROUP BY key and admitted aggregates"
                      else
                        "transform aggregate projection SELECT may list each GROUP BY key at most once and only with admitted aggregates"
                      end
            raise UnsupportedFormatError.new(message)
          end
          next
        end

        if count = /\Acount\s*\(\s*\)(?:\s+(?i:AS)\s+([\s\S]+))?\z/.match(token)
          descriptor = WidePartProjectionAggregateDescriptor.count
          unless aggregate_functions.add?(descriptor.function)
            raise UnsupportedFormatError.new("transform aggregate projection may contain count() only once")
          end
          count_seen = true
          columns << {descriptor.column_name, descriptor.type_name}
          if alias_token = count[1]?
            aliases << aggregate_alias!(alias_token, descriptor.function_name)
          end
          next
        end

        if /\Acount\s*\(/.matches?(token)
          raise UnsupportedFormatError.new("transform count projection SELECT must contain count() and optionally its group key")
        end

        if aggregate = /\A(sum|min|max)\s*\(\s*([\s\S]+?)\s*\)(?:\s+(?i:AS)\s+([\s\S]+))?\z/.match(token)
          argument_name = parse_identifier(aggregate[2])
          argument = argument_name.try { |name| target_columns.find { |column| column.name == name } }
          unless argument && !argument.alias_column && argument.key_candidate_column && argument.type == "UInt64"
            raise UnsupportedFormatError.new("transform #{aggregate[1]} projection requires one plain UInt64 target column")
          end
          unless argument.name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES
            raise UnsupportedFormatError.new("transform aggregate projection argument exceeds the writer column-name limit")
          end
          descriptor = WidePartProjectionAggregateDescriptor.for_function(aggregate[1], argument.name)
          unless aggregate_functions.add?(descriptor.function)
            raise UnsupportedFormatError.new("transform aggregate projection may contain each admitted function only once")
          end
          aggregate_arguments.add(argument.name)
          columns << {descriptor.column_name, descriptor.type_name}
          if alias_token = aggregate[3]?
            aliases << aggregate_alias!(alias_token, descriptor.function_name)
          end
          next
        end

        raise UnsupportedFormatError.new("transform aggregate projection SELECT supports only count(), sum(argument), min(argument), and max(argument)")
      end

      unless aggregate_functions.size > 0
        raise UnsupportedFormatError.new("transform aggregate projection SELECT requires at least one admitted aggregate")
      end
      validate_aggregate_aliases!(aliases, key_names, aggregate_arguments)
      binding = if group_keys.size == 1
                  PartSchemaBinding.new(group_keys[0].name, columns, "projection")
                else
                  PartSchemaBinding.new({group_keys[0].name, group_keys[1].name}, columns, "projection")
                end
      {binding, count_seen}
    end

    private def aggregate_alias!(token : String, function_name : String) : String
      alias_name = parse_identifier(token)
      unless alias_name && alias_name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES
        raise UnsupportedFormatError.new("transform #{function_name} projection alias must be a bounded ASCII identifier")
      end
      alias_name
    end

    private def validate_aggregate_aliases!(
      aliases : Array(String),
      key_names : Array(String),
      aggregate_arguments : Set(String),
    ) : Nil
      seen = Set(String).new
      aliases.each do |name|
        unless seen.add?(name) && !key_names.includes?(name) && !aggregate_arguments.includes?(name)
          message = if key_names.size == 1
                      "transform aggregate projection aliases must be unique and cannot shadow the key or aggregate arguments"
                    else
                      "transform aggregate projection aliases must be unique and cannot shadow a key or aggregate argument"
                    end
          raise UnsupportedFormatError.new(message)
        end
      end
      nil
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
