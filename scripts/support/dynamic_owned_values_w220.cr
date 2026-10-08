require "../../src/crystal_click"
require "json"

module CrystalClick
  module DynamicOwnedValuesW220
    struct Observation
      getter schema_declaration : String
      getter row_count : UInt64
      getter mark_row_counts : Array(UInt64)
      getter values_by_mark : Array(Array(BinaryValue))

      def initialize(
        @schema_declaration : String,
        @row_count : UInt64,
        mark_row_counts : Array(UInt64),
        values_by_mark : Array(Array(BinaryValue)),
      )
        @mark_row_counts = mark_row_counts.dup
        @values_by_mark = values_by_mark.map(&.dup)
      end
    end

    # Reopen the supplied physical part through the public OfflineTable.values
    # route. The independent fixture and direct reader observations are both
    # checked against the returned owned values before a witness is emitted.
    def self.materialize(
      part_path : String,
      column_name : String,
      nominal_type : BinaryDataType,
      expected_row_count : UInt64,
      expected_mark_rows : Array(UInt64),
      expected_by_mark : Array(Array(BinaryValue)),
      low_level_by_mark : Array(Array(BinaryValue)),
    ) : Observation
      full_path = File.expand_path(part_path)
      unless Dir.exists?(full_path) && !File.symlink?(full_path) && File.realpath(full_path) == full_path
        raise InvalidPartError.new("W220 source part is absent, noncanonical, or symlinked")
      end

      part_name = File.basename(full_path)
      part_info = MergeTreePartInfo.parse(part_name) || raise(InvalidPartError.new("W220 source part name is invalid"))
      unless expected_by_mark.size == expected_mark_rows.size && low_level_by_mark.size == expected_mark_rows.size
        raise CorruptPartError.new("W220 fixture and low-level mark counts differ")
      end

      expected_count = 0_u64
      expected_by_mark.each_with_index do |mark, mark_index|
        expected_mark_count = expected_mark_rows[mark_index]
        unless mark.size.to_u64 == expected_mark_count && low_level_by_mark[mark_index].size.to_u64 == expected_mark_count
          raise CorruptPartError.new("W220 fixture or low-level mark row count differs")
        end
        expected_count += expected_mark_count
      end
      unless expected_count == expected_row_count
        raise CorruptPartError.new("W220 fixture mark grid differs from nominal row count")
      end

      candidate = OfflinePartCandidate.new(part_name, full_path, part_info, expected_row_count)
      columns = [
        OfflineColumn.new("pk", "UInt64"),
        OfflineColumn.new(column_name, nominal_type.name),
      ] of OfflineColumn
      table = OfflineTable.new(
        "w220_owned_values",
        nil,
        "MergeTree",
        columns,
        [candidate] of OfflinePartCandidate,
        "pk",
      )
      declared_column = table.columns.find { |column| column.name == column_name }
      unless declared_column && declared_column.type == nominal_type.name
        raise CorruptPartError.new("W220 OfflineTable declaration differs from the exact fixture type")
      end

      result = table[column_name].values
      unless result.size.to_u64 == expected_row_count
        raise CorruptPartError.new("W220 OfflineTable.values row count differs from the part census")
      end

      owned_values = Array(BinaryValue).new(result.size)
      result.each_with_index do |item, index|
        value = item.as(BinaryValue)
        unless value.type == nominal_type && value.type.name == nominal_type.name
          raise CorruptPartError.new("W220 OfflineTable.values returned a different nominal descriptor at row #{index}")
        end
        owned_values << value
      end

      expected_values = [] of BinaryValue
      low_level_values = [] of BinaryValue
      expected_by_mark.each { |mark| expected_values.concat(mark) }
      low_level_by_mark.each { |mark| low_level_values.concat(mark) }
      unless expected_values.size == owned_values.size && low_level_values.size == owned_values.size
        raise CorruptPartError.new("W220 owned, fixture, and low-level result counts differ")
      end

      owned_values.each_with_index do |value, index|
        fixture_value = expected_values[index]
        reader_value = low_level_values[index]
        encoded = BinaryValueCodec.encode(value)
        unless fixture_value.type == nominal_type && reader_value.type == nominal_type &&
               encoded == BinaryValueCodec.encode(fixture_value) && encoded == BinaryValueCodec.encode(reader_value)
          raise CorruptPartError.new("W220 owned value, exact type, or actual payload differs at row #{index}")
        end
      end

      values_by_mark = Array(Array(BinaryValue)).new(expected_mark_rows.size)
      offset = 0
      expected_mark_rows.each do |mark_rows|
        values_by_mark << owned_values[offset, mark_rows.to_i]
        offset += mark_rows.to_i
      end
      Observation.new(nominal_type.name, expected_row_count, expected_mark_rows, values_by_mark)
    end

    def self.to_json(observation : Observation, &signature : BinaryValue -> String) : JSON::Any
      JSON::Any.new({
        "schema_declaration"         => JSON::Any.new(observation.schema_declaration),
        "row_count"                  => JSON::Any.new(observation.row_count.to_i64),
        "mark_row_counts"            => JSON::Any.new(observation.mark_row_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
        "nominal_type_names_by_mark" => JSON::Any.new(
          observation.values_by_mark.map do |mark|
            JSON::Any.new(mark.map { |value| JSON::Any.new(value.type.name) })
          end,
        ),
        "values_by_mark" => JSON::Any.new(
          observation.values_by_mark.map do |mark|
            JSON::Any.new(mark.map { |value| JSON::Any.new(yield value) })
          end,
        ),
      } of String => JSON::Any)
    end
  end
end
