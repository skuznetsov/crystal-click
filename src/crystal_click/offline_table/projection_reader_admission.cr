module CrystalClick
  class OfflineTable
    # Owns the shared admission and physical-reader construction for explicit
    # projection scans. The caller retains the materialized-view and exact
    # MergeTree fences; selected types belong to each projection child's schema.
    private class ProjectionReaderAdmission
      def self.open(
        table : OfflineTable,
        projection_name : String,
        columns : Array(String),
        row_limit : Int,
        row_limit_label : String,
      ) : (WidePartTable | TypedPartTable)?
        if projection_name.bytesize > WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
          raise BoundsError.new("projection child name exceeds limit")
        end
        unless /\A[A-Za-z0-9_]+\z/.matches?(projection_name)
          raise InvalidPartError.new("invalid projection name: #{projection_name}")
        end
        unless table.projections.any? { |projection| projection.name == projection_name }
          raise UnsupportedFormatError.new("selected projection is not declared by table DDL")
        end
        raise BoundsError.new("no columns selected") if columns.empty?
        raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS
        if row_limit <= 0 || row_limit > WidePartTable::MAX_BATCH_ROWS
          raise BoundsError.new("#{row_limit_label} row count is out of range")
        end

        selected = Set(String).new
        columns.each do |column_name|
          raise BoundsError.new("column name is empty or exceeds limit") if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
          raise BoundsError.new("duplicate selected column") if selected.includes?(column_name)
          selected << column_name
        end

        candidates = table.resolved_scan_parts
        return nil if candidates.empty?

        parent_paths = candidates.map(&.path)
        # Bound the selection and validate every parent/child path before the
        # routing probe reads any child manifest.
        selection = ProjectionChildSelection.prepare(parent_paths, projection_name)
        # Keep the established Wide projection reader intact for the common
        # all-Wide case. A set containing Compact marks uses TypedPartTable's
        # existing per-part schema, grid, limit, and schedule composition.
        if selection.contains_compact_child?
          TypedPartTable.open_selected_projection_typed(selection, columns)
        else
          WidePartTable.open_selected_projection_typed(parent_paths, projection_name, columns)
        end
      end
    end
  end
end
