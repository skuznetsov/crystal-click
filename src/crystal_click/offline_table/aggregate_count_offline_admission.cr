module CrystalClick
  class OfflineTable
    # Binds a selected Count state to the exact offline DDL key pair before a
    # table reader can invoke user callbacks. The part reader's retained key
    # name is derived from the same validated physical pair as Count itself;
    # the table reader separately opens that hidden sibling and checks axes.
    private class AggregateCountOfflineAdmission
      alias Plan = Tuple(String, String, BinaryDataType)

      def self.plan_for(table : OfflineTable, selected_columns : Array(String)) : Plan?
        declarations = table.columns
        count_column = nil.as(OfflineColumn?)
        count_storage = nil.as(WideAggregateCountStoragePlan?)

        selected_columns.each do |selected_name|
          declaration = declarations.find { |column| column.name == selected_name } || next
          storage = WideAggregateCountStoragePlan.for_type_name(declaration.type) || next
          if count_column
            raise UnsupportedFormatError.new("offline Count selection supports one state column")
          end
          count_column = declaration
          count_storage = storage
        end

        selected_count = count_column || return nil
        storage = count_storage || raise(CorruptPartError.new("selected Count storage plan disappeared"))
        validate_ddl_pair!(table, declarations, selected_count)

        key_name = table.primary_key_column ||
                   raise(UnsupportedFormatError.new("offline Count requires a simple UInt64 ORDER BY key"))
        {selected_count.name, key_name, storage.data_type}
      end

      def self.validate_candidates!(plan : Plan?, candidates : Array(OfflinePartCandidate)) : Nil
        return unless binding = plan

        count_name, expected_key_name, expected_type = binding
        candidates.each do |candidate|
          reader = WidePart.open_typed(candidate.path, column: count_name)
          unless reader.column_type == expected_type.name
            raise UnsupportedFormatError.new("table DDL and selected Count part types differ")
          end
          unless reader.row_count == candidate.row_count
            raise CorruptPartError.new("selected Count part row count differs from its catalog candidate")
          end

          part_key_name = reader.aggregate_count_key_column_name
          unless part_key_name == expected_key_name
            raise UnsupportedFormatError.new("selected Count part sibling differs from the DDL ORDER BY key")
          end
        end
        nil
      end

      private def self.validate_ddl_pair!(
        table : OfflineTable,
        declarations : Array(OfflineColumn),
        count_column : OfflineColumn,
      ) : Nil
        unless table.kind == :table && table.engine == "MergeTree"
          raise UnsupportedFormatError.new("offline Count requires persisted ordinary MergeTree table DDL")
        end
        raise UnsupportedFormatError.new("offline Count requires persisted ordinary MergeTree table DDL") unless table.metadata_ddl
        unless declarations.size == 2
          raise UnsupportedFormatError.new("offline Count requires exactly one UInt64 key and one Count column")
        end
        unless !count_column.alias_column && count_column.key_candidate_column &&
               WideAggregateCountStoragePlan.for_type_name(count_column.type) != nil
          raise UnsupportedFormatError.new("offline Count declaration must be one exact bare admitted descriptor")
        end

        key_name = table.primary_key_column ||
                   raise(UnsupportedFormatError.new("offline Count requires a simple UInt64 ORDER BY key"))
        key_column = declarations.find { |column| column.name == key_name }
        unless key_column && key_column.name != count_column.name && key_column.type == "UInt64" &&
               !key_column.alias_column && key_column.key_candidate_column
          raise UnsupportedFormatError.new("offline Count ORDER BY key must be the other bare UInt64 declaration")
        end
        unless declarations.all? { |column| !column.alias_column && column.key_candidate_column }
          raise UnsupportedFormatError.new("offline Count declarations cannot use aliases or modifiers")
        end
        nil
      end
    end
  end
end
