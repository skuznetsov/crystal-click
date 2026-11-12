module CrystalClick
  # DDL-derived child schemas for one caller-run transform. The catalog builds
  # this before invoking caller code, then binds the supplied immutable child
  # owners after the full scan and exact metadata revalidation.
  private class OfflineTransformProjectionBindings
    @schema_by_name : Hash(String, PartSchemaBinding)

    private def initialize(target : OfflineTable, parent_target : String)
      projections = target.projections
      if projections.size > WidePartWriter::MAX_PROJECTIONS
        raise UnsupportedFormatError.new("transform target projection count exceeds the writer limit")
      end

      target_columns = target.columns
      @schema_by_name = Hash(String, PartSchemaBinding).new(initial_capacity: projections.size)
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

        match = /\ASELECT\b([\s\S]*?)\s+ORDER\s+BY\s+([\s\S]+)\z/i.match(projection.definition.strip)
        unless match
          raise UnsupportedFormatError.new("transform projection must be a simple SELECT column list ordered by its key")
        end

        selected = match[1].split(',')
        if selected.size < 2
          raise UnsupportedFormatError.new("transform projection SELECT must list the target UInt64 key followed by value columns")
        end

        selected_columns = Array(OfflineColumn).new(selected.size)
        seen_columns = Set(String).new
        selected.each do |token|
          identifier = /\A(?:`([A-Za-z_][A-Za-z0-9_]*)`|([A-Za-z_][A-Za-z0-9_]*))\z/.match(token.strip)
          unless identifier
            raise UnsupportedFormatError.new("transform projection SELECT supports only plain named target columns")
          end
          name = identifier[1]? || identifier[2]?
          unless name && seen_columns.add?(name)
            raise UnsupportedFormatError.new("transform projection SELECT columns must be unique")
          end
          column = target_columns.find { |candidate| candidate.name == name }
          unless column && !column.alias_column && column.key_candidate_column
            raise UnsupportedFormatError.new("transform projection SELECT must reference plain target columns")
          end
          selected_columns << column
        end

        projection_key = selected_columns.first
        order_key = parse_simple_ascending_key_expression(match[2])
        unless projection_key.type == "UInt64" && order_key == projection_key.name
          raise UnsupportedFormatError.new("transform projection ORDER BY must match its first selected UInt64 key")
        end

        schema_columns = selected_columns.map { |column| {column.name, column.type} }
        binding = PartSchemaBinding.new(projection_key.name, schema_columns, "projection")
        if @schema_by_name.has_key?(projection_name)
          raise UnsupportedFormatError.new("transform target projection names must be unique")
        end
        @schema_by_name[projection_name] = binding
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
        binding = @schema_by_name[projection.name]?
        unless binding
          raise UnsupportedFormatError.new("transform projection output roster does not match target DDL")
        end
        unless projection.key_name == binding.key_name
          raise UnsupportedFormatError.new("transform projection output key does not match target schema")
        end
        unless projection.row_count == parent_rows
          raise UnsupportedFormatError.new("transform projection output row count does not match parent row count")
        end

        retained << projection.with_schema_binding(binding)
      end
      retained
    end

    private def parse_simple_ascending_key_expression(expression : String) : String?
      match = /\A(?:`([A-Za-z_][A-Za-z0-9_]*)`|([A-Za-z_][A-Za-z0-9_]*))(?:\s+ASC)?\z/i.match(expression.strip)
      return nil unless match
      match[1]? || match[2]?
    end
  end
end
