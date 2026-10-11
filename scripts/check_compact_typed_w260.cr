require "../src/crystal_click"
require "json"
require "file_utils"
require "./support/compact_physical_context_w259_fixture"
require "./support/compact_typed_w260_fixture"

module CheckCompactTypedW260
  FORMAT = "compact_typed_w260_helper_v1"

  alias SignatureScan = NamedTuple(
    keys: Array(UInt64),
    columns: Hash(String, Array(String)),
    callback_rows: Array(Int32),
    offsets: Array(Tuple(Int32, UInt64, UInt64)),
  )

  alias TableReport = NamedTuple(
    columns: Array(String),
    column_types: Array(Tuple(String, String)),
    column_sources: Array(Tuple(String, String, String)),
    part_mark_row_counts: Array(Array(UInt64)),
    total_row_count: UInt64,
    full: SignatureScan,
    first: SignatureScan,
    middle: SignatureScan,
    last: SignatureScan,
    eof: SignatureScan,
    candidates: SignatureScan,
    one_row_batches: SignatureScan,
  )

  alias MvSourceReport = NamedTuple(
    source_table: String,
    output_path: String,
    callback_count: Int32,
    row_count: UInt64,
    offsets: Array(Tuple(Int32, UInt64, UInt64)),
    keys: Array(UInt64),
    values: Array(String),
  )

  alias PhysicalColumnReport = NamedTuple(
    column: String,
    logical_bytes: UInt64,
    shard_bytes: UInt64,
  )

  alias MixedScan = NamedTuple(
    keys: Array(UInt64),
    strings: Array(String),
    offsets: Array(Tuple(Int32, Int32, UInt64, UInt64, UInt64)),
  )

  alias MixedReport = NamedTuple(
    full: MixedScan,
    window: MixedScan,
    candidates: MixedScan,
    schedule_mutated: Bool,
  )

  def self.hex(value : String) : String
    String.build do |io|
      value.to_slice.each do |byte|
        io << byte.to_s(16).rjust(2, '0')
      end
    end
  end

  def self.string_signature(value : String) : String
    "string:#{hex(value)}"
  end

  def self.uint64_signature(value : UInt64) : String
    "uint64:#{value}"
  end

  def self.nullable_uint64_signature(value : UInt64?) : String
    value ? uint64_signature(value) : "null"
  end

  def self.variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "variant<String>(string:#{hex(value)})"
    when UInt64
      "variant<UInt64>(uint64:#{value})"
    else
      "variant<NULL>(null)"
    end
  end

  # Generic static columns keep the existing BinaryValue carrier. The helper
  # serializes only the closed Schema-B tree used by the independent native
  # fixture; an unexpected type is a hard harness error.
  def self.binary_signature(value : CrystalClick::BinaryValue) : String
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_UINT64
      uint64_signature(value.as_uint64)
    when CrystalClick::BinaryDataType::TAG_STRING
      string_signature(value.as_string)
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      value.is_null? ? "null" : binary_signature(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_ARRAY
      children = value.elements.map { |child| binary_signature(child) }
      "array[#{children.join(',')}]"
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      "lowcard(#{binary_signature(value.child_at(0))})"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      if value.is_null?
        "variant<NULL>(null)"
      else
        index = value.variant_index?.not_nil!.to_i
        arm = type.child_at(index).name
        "variant<#{arm}>(#{binary_signature(value.variant_child?.not_nil!)})"
      end
    when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      children = value.elements
      fields = Array(String).new(children.size)
      children.each_with_index do |child, index|
        name = type.tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE ? type.field_name_at(index) : index.to_s
        fields << "#{name}=#{binary_signature(child)}"
      end
      "tuple[#{fields.join(',')}]"
    else
      raise CrystalClick::UnsupportedFormatError.new("W260 harness has no BinaryValue formatter for #{type.name}")
    end
  end

  def self.map_signature(values : Array(Tuple(String, Array(UInt64?)))) : String
    entries = values.map do |entry|
      key, children = entry
      "#{hex(key)}:[#{children.map { |child| nullable_uint64_signature(child) }.join(',')}]"
    end
    "map[#{entries.join(',')}]"
  end

  def self.tuple_signature(row : CrystalClick::WideTupleRow) : String
    fields = row.fields.map do |field|
      name = field.name
      type = field.type_name
      value = row[name]
      rendered = if type == "String"
                   string_signature(value.as(String))
                 elsif type == "UInt64"
                   uint64_signature(value.as(UInt64))
                 elsif type == "Nullable(UInt64)"
                   nullable_uint64_signature(value.as(UInt64?))
                 else
                   raise CrystalClick::UnsupportedFormatError.new("W260 tuple formatter rejected field type #{type}")
                 end
      "#{name}=#{rendered}"
    end
    "tuple[#{fields.join(',')}]"
  end

  def self.array_tuple_signature(row : CrystalClick::WideArrayTupleRow) : String
    children = Array(String).new
    row.each { |tuple| children << tuple_signature(tuple) }
    "array[#{children.join(',')}]"
  end

  def self.append_batch(
    batch : CrystalClick::WidePartTableBatch,
    label : String,
    columns : Array(String),
    signatures : Hash(String, Array(String)),
  ) : Array(UInt64)
    keys = batch.values_for("pk", UInt64)
    before = Hash(String, Int32).new
    columns.reject { |column| column == "pk" }.each { |column| before[column] = signatures[column].size }

    if CompactTypedW260Fixture::SCHEMA_A_LABELS.includes?(label) || label == "wide_control"
      if columns.includes?("s")
        batch.strings_for("s").each { |value| signatures["s"] << string_signature(value) }
      end
      if columns.includes?("n")
        batch.nullable_values_for("n", UInt64).each { |value| signatures["n"] << nullable_uint64_signature(value) }
      end
      if columns.includes?("arr")
        batch.array_nullable_uint64s_for("arr").each do |row|
          children = row.map { |value| nullable_uint64_signature(value) }
          signatures["arr"] << "array[#{children.join(',')}]"
        end
      end
      if columns.includes?("pair")
        batch.tuple_rows_for("pair").each { |row| signatures["pair"] << tuple_signature(row) }
      end
      if columns.includes?("seq")
        batch.array_tuple_rows_for("seq").each { |row| signatures["seq"] << array_tuple_signature(row) }
      end
      if columns.includes?("lookup")
        batch.map_string_array_nullable_uint64s_for("lookup").each do |row|
          signatures["lookup"] << map_signature(row)
        end
      end
      if columns.includes?("lc")
        batch.low_cardinality_strings_for("lc").each { |value| signatures["lc"] << string_signature(value) }
      end
      if columns.includes?("v")
        batch.variant_string_uint64_for("v").each { |value| signatures["v"] << variant_signature(value) }
      end
    else
      if columns.includes?("label")
        batch.strings_for("label").each { |value| signatures["label"] << string_signature(value) }
      end
      if columns.includes?("pair")
        batch.binary_bulk_values_for("pair").each { |value| signatures["pair"] << binary_signature(value) }
      end
    end

    columns.reject { |column| column == "pk" }.each do |column|
      unless signatures[column].size - before[column] == keys.size
        raise CrystalClick::CorruptPartError.new("W260 typed batch #{column} row count differs from its keys")
      end
    end
    keys.to_a
  end

  def self.empty_signatures(columns : Array(String)) : Hash(String, Array(String))
    columns.reject { |column| column == "pk" }.each_with_object(Hash(String, Array(String)).new) do |column, result|
      result[column] = [] of String
    end
  end

  def self.read_with(table, label : String, columns : Array(String), mode : Symbol, start : UInt64 = 0_u64, rows : Int = 8, candidates : Array(Array(Int32))? = nil, batch_rows : Int = 4_096) : SignatureScan
    keys = [] of UInt64
    signatures = empty_signatures(columns)
    callback_rows = [] of Int32
    offsets = [] of Tuple(Int32, UInt64, UInt64)
    consume = ->(batch : CrystalClick::WidePartTableBatch) {
      observed_keys = append_batch(batch, label, columns, signatures)
      keys.concat(observed_keys)
      callback_rows << observed_keys.size.to_i32
      offsets << {batch.mark_index, batch.source_row_offset, batch.row_count || observed_keys.size.to_u64}
      nil
    }

    case mode
    when :full
      table.scan_typed(batch_rows: batch_rows, &consume)
    when :window
      table.scan_typed_window(start, rows, &consume)
    when :candidates
      selected = candidates || raise ArgumentError.new("candidate schedule is required")
      table.scan_typed_candidate_marks(selected, &consume)
    else
      raise ArgumentError.new("unknown W260 scan mode")
    end
    {keys: keys, columns: signatures, callback_rows: callback_rows, offsets: offsets}
  end

  def self.assert_windows(report : TableReport, label : String) : Nil
    combined_keys = report[:first][:keys] + report[:middle][:keys] + report[:last][:keys]
    raise CrystalClick::CorruptPartError.new("W260 #{label} row windows do not reconstruct full keys") unless combined_keys == report[:full][:keys]
    report[:full][:columns].each do |column, values|
      combined = report[:first][:columns][column] + report[:middle][:columns][column] + report[:last][:columns][column]
      raise CrystalClick::CorruptPartError.new("W260 #{label} row windows do not reconstruct #{column}") unless combined == values
    end
    raise CrystalClick::CorruptPartError.new("W260 #{label} EOF window returned rows") unless report[:eof][:keys].empty?
    raise CrystalClick::CorruptPartError.new("W260 #{label} zero window returned values") unless report[:eof][:columns].values.all?(&.empty?)
    raise CrystalClick::CorruptPartError.new("W260 #{label} 1-row scan was not bounded") unless report[:one_row_batches][:callback_rows].all? { |count| count == 1 }
    raise CrystalClick::CorruptPartError.new("W260 #{label} 1-row scan has wrong callback count") unless report[:one_row_batches][:callback_rows].size == report[:full][:keys].size
    expected_offsets = (0..7).map do |row|
      {row // 2, row.to_u64, 1_u64}
    end
    unless report[:one_row_batches][:offsets] == expected_offsets
      raise CrystalClick::CorruptPartError.new("W260 #{label} 1-row scan source offsets or mark identities differ")
    end
    nil
  end

  def self.expected_a_signatures(columns : Array(String) = CompactTypedW260Fixture::SELECTED_A) : Hash(String, Array(String))
    expected = Hash(String, Array(String)).new
    expected["s"] = (0..7).map { |index| string_signature("root-#{index}") }
    expected["n"] = ["null", "uint64:7202", "null", "uint64:7204", "null", "uint64:7206", "uint64:7207", "null"]
    expected["arr"] = [
      "array[]", "array[]", "array[null,uint64:17]", "array[uint64:23]",
      "array[]", "array[]", "array[uint64:7,uint64:8,null]", "array[null,uint64:9]",
    ]
    expected["pair"] = (0..7).map do |index|
      "tuple[left=#{string_signature("left-#{index}")},right=#{string_signature("right-#{index}")},code=uint64:#{7301 + index}]"
    end
    expected["seq"] = [
      "array[]", "array[]",
      "array[tuple[label=#{string_signature("a")},value=null],tuple[label=#{string_signature("b")},value=uint64:7403]]",
      "array[]", "array[]", "array[]",
      "array[tuple[label=#{string_signature("z")},value=uint64:7407]]",
      "array[tuple[label=#{string_signature("tail")},value=null]]",
    ]
    expected["lookup"] = [
      "map[]", "map[]", "map[61:[null,uint64:7503]]", "map[]", "map[]", "map[]",
      "map[78:[uint64:7507,uint64:7508],656d707479:[]]",
      "map[7461696c:[null,uint64:7508]]",
    ]
    expected["lc"] = ["dup", "dup", "green", "", "blue", "blue", "dup", "tail"].map { |value| string_signature(value) }
    expected["v"] = [
      "variant<String>(#{string_signature("repeat")})", "variant<String>(#{string_signature("repeat")})",
      "variant<UInt64>(uint64:7603)", "variant<UInt64>(uint64:7603)",
      "variant<NULL>(null)", "variant<NULL>(null)",
      "variant<String>(#{string_signature("last")})", "variant<UInt64>(uint64:7608)",
    ]
    expected.select { |column, _values| columns.includes?(column) }
  end

  def self.expected_b_signatures : Hash(String, Array(String))
    expected = Hash(String, Array(String)).new
    expected["label"] = (0..7).map { |index| string_signature("b-#{index}") }
    expected["pair"] = [
      "tuple[l=array[],v=array[]]", "tuple[l=array[],v=array[]]",
      "tuple[l=array[lowcard(uint64:42),lowcard(uint64:42)],v=array[variant<String>(#{string_signature("inside-2")}),variant<UInt64>(uint64:8203)]]",
      "tuple[l=array[lowcard(uint64:43)],v=array[variant<UInt64>(uint64:8204)]]",
      "tuple[l=array[],v=array[]]", "tuple[l=array[],v=array[]]",
      "tuple[l=array[lowcard(uint64:42)],v=array[variant<String>(#{string_signature("inside-6")})]]",
      "tuple[l=array[lowcard(uint64:44)],v=array[variant<UInt64>(uint64:8208)]]",
    ]
    expected
  end

  def self.assert_literal_values(report : TableReport, label : String) : Nil
    expected = if label.starts_with?("b_")
                 expected_b_signatures
               elsif label == "wide_control"
                 expected_a_signatures(CompactTypedW260Fixture::SELECTED_WIDE)
               else
                 expected_a_signatures
               end
    keys = label.starts_with?("b_") ? (8101_u64..8108_u64).to_a : (7101_u64..7108_u64).to_a
    raise CrystalClick::CorruptPartError.new("W260 #{label} full keys differ from independent literals") unless report[:full][:keys] == keys
    raise CrystalClick::CorruptPartError.new("W260 #{label} full typed values differ from independent literals") unless report[:full][:columns] == expected

    [{report[:first], 0, 2}, {report[:middle], 2, 4}, {report[:last], 6, 2}].each do |scan, start, count|
      expected_keys = keys[start, count]
      expected_values = expected.transform_values { |values| values[start, count] }
      unless scan[:keys] == expected_keys && scan[:columns] == expected_values
        raise CrystalClick::CorruptPartError.new("W260 #{label} typed row window differs from independent literals")
      end
    end

    expected_candidate_keys = keys[0, 2] + keys[4, 2]
    expected_candidate_values = expected.transform_values { |values| values[0, 2] + values[4, 2] }
    unless report[:candidates][:keys] == expected_candidate_keys && report[:candidates][:columns] == expected_candidate_values
      raise CrystalClick::CorruptPartError.new("W260 #{label} candidate marks differ from independent literals")
    end
    unless report[:one_row_batches][:keys] == keys && report[:one_row_batches][:columns] == expected
      raise CrystalClick::CorruptPartError.new("W260 #{label} one-row batches differ from independent literals")
    end
    nil
  end

  def self.inspect_table(table, label : String, columns : Array(String)) : TableReport
    mark_rows = table.part_mark_row_counts
    expected_marks = [[2_u64, 2_u64, 2_u64, 2_u64]]
    raise CrystalClick::CorruptPartError.new("W260 #{label} mark rows differ from [2,2,2,2]") unless mark_rows == expected_marks
    raise CrystalClick::CorruptPartError.new("W260 #{label} total rows differ from 8") unless table.total_row_count == 8_u64

    full = read_with(table, label, columns, :full, rows: 8)
    first = read_with(table, label, columns, :window, 0_u64, 2)
    middle = read_with(table, label, columns, :window, 2_u64, 4)
    last = read_with(table, label, columns, :window, 6_u64, 2)
    eof = read_with(table, label, columns, :window, 8_u64, 2)
    candidates = read_with(table, label, columns, :candidates, candidates: [[0_i32, 2_i32]])
    one_row = read_with(table, label, columns, :full, rows: 8, batch_rows: 1)

    report = {
      columns: table.columns,
      column_types: table.column_types,
      column_sources: table.column_sources,
      part_mark_row_counts: mark_rows,
      total_row_count: table.total_row_count,
      full: full, first: first, middle: middle, last: last, eof: eof,
      candidates: candidates, one_row_batches: one_row,
    }
    assert_windows(report, label)
    assert_literal_values(report, label)
    report
  end

  def self.window_shard_bytes(window : CrystalClick::CompactPartPhysicalWindow) : UInt64
    total = 0_u64
    window.granules.each do |granule|
      granule.shards.each do |shard|
        size = shard.bytes.size.to_u64
        raise CrystalClick::CorruptPartError.new("W260 physical shard-byte sum overflows") if size > UInt64::MAX - total
        total += size
      end
    end
    total
  end

  def self.inspect_physical(path : String) : Array(PhysicalColumnReport)
    context = CrystalClick::CompactPartPhysicalContext.open(path)
    reports = [] of PhysicalColumnReport
    context.columns.each do |column, _type|
      logical_bytes = context.logical_bytes_for(column)
      full_window = context.read_window(column, 0, context.granule_count)
      shard_bytes = window_shard_bytes(full_window)
      unless logical_bytes == shard_bytes
        raise CrystalClick::CorruptPartError.new("W260 #{column} logical bytes differ from its complete physical shard grid")
      end
      reports << {column: column, logical_bytes: logical_bytes, shard_bytes: shard_bytes}
    end
    reports
  end

  def self.inspect_two_column_physical : NamedTuple(columns: Array(String), logical_bytes: UInt64, shard_bytes: UInt64)
    root = File.tempname("crystal-click-w260-physical-columns-")
    begin
      part = File.join(root, "all_1_1_0")
      CompactPhysicalContextW259Fixture.build(part, CrystalClick::CompactMarkFormat::Mrk4)
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      columns = ["alpha", "beta"]
      logical_bytes = 0_u64
      shard_bytes = 0_u64
      columns.each do |column|
        size = context.logical_bytes_for(column)
        raise CrystalClick::CorruptPartError.new("W260 two-column logical bytes overflow") if size > UInt64::MAX - logical_bytes
        logical_bytes += size
        shard_size = window_shard_bytes(context.read_window(column, 0, context.granule_count))
        raise CrystalClick::CorruptPartError.new("W260 two-column shard bytes overflow") if shard_size > UInt64::MAX - shard_bytes
        shard_bytes += shard_size
      end
      unless logical_bytes == shard_bytes
        raise CrystalClick::CorruptPartError.new("W260 two-column logical bytes differ from disjoint shard ownership")
      end
      {columns: columns, logical_bytes: logical_bytes, shard_bytes: shard_bytes}
    ensure
      FileUtils.rm_rf(root)
    end
  end

  def self.read_mixed(
    table : CrystalClick::TypedPartTable,
    mode : Symbol,
    schedule : Array(Array(Int32))? = nil,
    mutate_schedule : Bool = false,
  ) : Tuple(MixedScan, Bool)
    keys = [] of UInt64
    strings = [] of String
    offsets = [] of Tuple(Int32, Int32, UInt64, UInt64, UInt64)
    mutated = false
    consume = ->(batch : CrystalClick::WidePartTableBatch) {
      batch.values_for("pk", UInt64).each { |value| keys << value }
      batch.strings_for("s").each { |value| strings << String.new(value.to_slice) }
      count = batch.row_count || raise CrystalClick::CorruptPartError.new("W260 mixed callback omitted row count")
      unless batch.values_for("pk", UInt64).size.to_u64 == count && batch.strings_for("s").size.to_u64 == count
        raise CrystalClick::CorruptPartError.new("W260 mixed callback column lengths differ")
      end
      offsets << {batch.part_index, batch.mark_index, batch.part_row_offset, batch.source_row_offset, count}
      if mutate_schedule && !mutated
        selected = schedule || raise ArgumentError.new("W260 candidate schedule was not supplied")
        selected.each(&.clear)
        mutated = true
      end
      nil
    }

    case mode
    when :full
      table.scan_typed(batch_rows: 1, &consume)
    when :window
      table.scan_typed_window(6_u64, 4, &consume)
    when :candidates
      selected = schedule || raise ArgumentError.new("W260 candidate schedule was not supplied")
      table.scan_typed_candidate_marks(selected, &consume)
    else
      raise ArgumentError.new("unknown W260 mixed scan mode")
    end
    { {keys: keys, strings: strings, offsets: offsets}, mutated }
  end

  def self.inspect_mixed_facade(wide_path : String, compact_path : String) : MixedReport
    root = File.tempname("crystal-click-w260-mixed-parts-")
    begin
      Dir.mkdir_p(root)
      wide_copy = File.join(root, "all_1_1_0")
      compact_copy = File.join(root, "all_2_2_0")
      FileUtils.cp_r(wide_path, wide_copy)
      FileUtils.cp_r(compact_path, compact_copy)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [wide_copy, compact_copy],
        ["pk", "s"],
      )

      invalid_schedules = [
        [[0_i32, 2_i32], [4_i32]],
        [[0_i32, 2_i32], [2_i32, 2_i32]],
      ]
      invalid_schedules.each do |invalid_schedule|
        emitted = false
        rejected = false
        begin
          table.scan_typed_candidate_marks(invalid_schedule) { |_batch| emitted = true }
        rescue ex : CrystalClick::BoundsError
          rejected = true
        end
        unless rejected && !emitted
          raise CrystalClick::CorruptPartError.new("W260 mixed candidate schedule was not rejected before callbacks")
        end
      end

      full, _ = read_mixed(table, :full)
      window, _ = read_mixed(table, :window)
      schedule = [[1_i32, 3_i32], [0_i32, 2_i32]]
      candidates, mutated = read_mixed(table, :candidates, schedule, true)

      expected_keys_one = (7101_u64..7108_u64).to_a
      expected_keys = expected_keys_one + expected_keys_one
      expected_strings_one = (0..7).map { |index| "root-#{index}" }
      expected_strings = expected_strings_one + expected_strings_one
      expected_full_offsets = (0..1).flat_map do |part|
        (0..7).map do |row|
          {part.to_i32, row // 2, row.to_u64, (part * 8 + row).to_u64, 1_u64}
        end
      end
      unless full[:keys] == expected_keys && full[:strings] == expected_strings && full[:offsets] == expected_full_offsets
        raise CrystalClick::CorruptPartError.new("W260 mixed full scan values or coordinates differ")
      end

      expected_window_keys = [7107_u64, 7108_u64, 7101_u64, 7102_u64]
      expected_window_strings = ["root-6", "root-7", "root-0", "root-1"]
      expected_window_offsets = [
        {0_i32, 3_i32, 6_u64, 6_u64, 2_u64},
        {1_i32, 0_i32, 0_u64, 8_u64, 2_u64},
      ]
      unless window[:keys] == expected_window_keys && window[:strings] == expected_window_strings && window[:offsets] == expected_window_offsets
        raise CrystalClick::CorruptPartError.new("W260 mixed row window values or rebased coordinates differ")
      end

      expected_candidate_keys = [7103_u64, 7104_u64, 7107_u64, 7108_u64, 7101_u64, 7102_u64, 7105_u64, 7106_u64]
      expected_candidate_strings = ["root-2", "root-3", "root-6", "root-7", "root-0", "root-1", "root-4", "root-5"]
      expected_candidate_offsets = [
        {0_i32, 1_i32, 2_u64, 2_u64, 2_u64},
        {0_i32, 3_i32, 6_u64, 6_u64, 2_u64},
        {1_i32, 0_i32, 0_u64, 8_u64, 2_u64},
        {1_i32, 2_i32, 4_u64, 12_u64, 2_u64},
      ]
      unless candidates[:keys] == expected_candidate_keys && candidates[:strings] == expected_candidate_strings && candidates[:offsets] == expected_candidate_offsets && mutated && schedule.all?(&.empty?)
        raise CrystalClick::CorruptPartError.new("W260 mixed candidate values, cloned schedule, or rebased coordinates differ")
      end
      {full: full, window: window, candidates: candidates, schedule_mutated: mutated}
    ensure
      FileUtils.rm_rf(root)
    end
  end

  def self.offline_value_signature(column : String, value : CrystalClick::OfflineColumnValue) : String
    case column
    when "pk"
      uint64_signature(value.as(UInt64))
    when "s", "label", "lc"
      string_signature(value.as(String))
    when "n"
      nullable_uint64_signature(value.as(UInt64?))
    when "arr"
      children = value.as(Array(UInt64?)).map { |child| nullable_uint64_signature(child) }
      "array[#{children.join(',')}]"
    when "pair"
      case value
      when CrystalClick::WideTupleRow
        tuple_signature(value)
      when CrystalClick::BinaryValue
        binary_signature(value)
      else
        raise CrystalClick::CorruptPartError.new("W260 catalog pair carrier changed")
      end
    when "seq"
      array_tuple_signature(value.as(CrystalClick::WideArrayTupleRow))
    when "lookup"
      map_signature(value.as(Array(Tuple(String, Array(UInt64?)))))
    when "v"
      variant_signature(value.as(CrystalClick::VariantStringUInt64Value))
    else
      raise CrystalClick::UnsupportedFormatError.new("W260 catalog formatter lacks column #{column}")
    end
  end

  def self.catalog_report(
    catalog_root : String,
    table_name : String,
    label : String,
    columns : Array(String),
  ) : NamedTuple(
    values: Hash(String, Array(String)),
    candidate_keys: Array(UInt64),
    candidate_mark_indices: Array(Int32),
    candidate_callback_rows: Array(Int32),
    candidate_filtered_keys: Array(UInt64),
    label: String,
  )
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    table = catalog["default"][table_name]
    values = Hash(String, Array(String)).new
    columns.each do |column|
      values[column] = table[column].values.map { |value| offline_value_signature(column, value) }
    end

    candidate_keys = [] of UInt64
    candidate_marks = [] of Int32
    candidate_rows = [] of Int32
    first_key = label.starts_with?("b_") ? 8103_u64 : 7103_u64
    table.scan_uint64_pk_candidates(["pk"], first_key, first_key + 3) do |batch|
      current = batch.values_for("pk", UInt64)
      candidate_marks << batch.mark_index
      candidate_keys.concat(current)
      candidate_rows << current.size.to_i32
    end
    expected_candidate_keys = [first_key, first_key + 1, first_key + 2, first_key + 3]
    # PrimaryKeyIndex deliberately includes the predecessor granule for a
    # lower bound and returns whole granules. For these two-row marks, range
    # [7103,7106] (or [8103,8106]) therefore schedules marks 0,1,2; callers
    # must still apply their exact row predicate to the conservative superset.
    conservative_keys = (first_key - 2_u64..first_key + 3_u64).to_a
    filtered_candidate_keys = candidate_keys.select { |key| key >= first_key && key <= first_key + 3_u64 }
    unless candidate_keys == conservative_keys && candidate_marks == [0, 1, 2] &&
           candidate_rows == [2, 2, 2] && filtered_candidate_keys == expected_candidate_keys
      raise CrystalClick::CorruptPartError.new("W260 catalog PK candidates differ from independent mark literals for #{label}")
    end
    {
      values:                  values,
      candidate_keys:          candidate_keys,
      candidate_mark_indices:  candidate_marks,
      candidate_callback_rows: candidate_rows,
      candidate_filtered_keys: filtered_candidate_keys,
      label:                   label,
    }
  end

  # Exercise the actual offline MV source owner with a stock Compact part.
  # The transform is caller-owned; this witness only verifies that the typed
  # source batches preserve exact values and row offsets before publication.
  def self.mv_source_report(catalog_root : String, source_table : String, target_path : String) : MvSourceReport
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    callback_count = 0_i32
    row_count = 0_u64
    offsets = [] of Tuple(Int32, UInt64, UInt64)
    keys = [] of UInt64
    values = [] of String

    output_path = catalog.transform_materialized_view_part(
      "default",
      "w260_mv",
      "all_1_1_0",
      ["pk", "s"],
      "all_9_9_0",
      rows_per_mark: 2,
      batch_rows: 1,
    ) do |input|
      callback_count += 1
      raise CrystalClick::CorruptPartError.new("W260 MV source declarations differ") unless input.column_names == ["pk", "s"] && input.column_types == [{"pk", "UInt64"}, {"s", "String"}]
      raise CrystalClick::CorruptPartError.new("W260 MV source row count differs") unless input.row_count == 8_u64

      output_keys = [] of UInt64
      output_values = [] of CrystalClick::BinaryValue
      input.each_batch do |batch|
        batch_keys = batch.values_for("pk", UInt64)
        batch_strings = batch.strings_for("s")
        count = batch.row_count || raise CrystalClick::CorruptPartError.new("W260 MV source batch omitted row count")
        raise CrystalClick::CorruptPartError.new("W260 MV source batch was not one row") unless count == 1_u64 && batch_keys.size == 1 && batch_strings.size == 1
        offsets << {batch.mark_index, batch.source_row_offset, count}
        row_count += count
        batch_keys.each_with_index do |key, index|
          value = String.new(batch_strings[index].to_slice)
          keys << key
          values << value
          output_keys << key
          output_values << CrystalClick::BinaryValue.string("mv-#{value}")
        end
      end

      output_marks = output_values.each_slice(2).map(&.to_a).to_a
      unless output_marks.size == 4 && output_marks.all? { |mark| mark.size == 2 }
        raise CrystalClick::CorruptPartError.new("W260 MV output rows do not match the two-row target granularity")
      end
      column = CrystalClick::WidePartColumn.binary_bulk(
        "value",
        CrystalClick::BinaryDataType.primitive("String"),
        output_marks,
      )
      CrystalClick::WidePartTransformOutput.new(output_keys.to_unsafe.to_slice(output_keys.size), [column])
    end

    expected_keys = (7101_u64..7108_u64).to_a
    expected_values = (0..7).map { |index| "root-#{index}" }
    expected_offsets = (0..7).map { |row| {row // 2, row.to_u64, 1_u64} }
    unless callback_count == 1 && row_count == 8_u64 && keys == expected_keys && values == expected_values && offsets == expected_offsets
      raise CrystalClick::CorruptPartError.new("W260 MV source values or source-row offsets differ from independent literals")
    end

    written_part = File.join(target_path, "detached", "all_9_9_0")
    unless File.expand_path(output_path) == File.expand_path(written_part)
      raise CrystalClick::CorruptPartError.new("W260 MV writer returned a different target destination")
    end
    output = CrystalClick::WidePartTable.open_selected_typed([written_part], ["id", "value"])
    unless output.part_mark_row_counts == [[2_u64, 2_u64, 2_u64, 2_u64]]
      raise CrystalClick::CorruptPartError.new("W260 MV output part mark grid differs from the two-row target granularity")
    end
    output_keys = [] of UInt64
    output_values = [] of String
    output.scan_typed(batch_rows: 1) do |batch|
      batch.values_for("id", UInt64).each { |key| output_keys << key }
      batch.strings_for("value").each { |value| output_values << String.new(value.to_slice) }
    end
    expected_output_values = expected_values.map { |value| "mv-#{value}" }
    unless output_keys == expected_keys && output_values == expected_output_values
      raise CrystalClick::CorruptPartError.new("W260 MV output part differs from the caller transform's exact literals")
    end

    {
      source_table:   source_table,
      output_path:    written_part,
      callback_count: callback_count,
      row_count:      row_count,
      offsets:        offsets,
      keys:           keys,
      values:         values,
    }
  end

  def self.write_scan(json : JSON::Builder, scan : SignatureScan) : Nil
    json.object do
      json.field "keys", scan[:keys]
      json.field "columns" do
        json.object do
          scan[:columns].keys.sort.each { |column| json.field column, scan[:columns][column] }
        end
      end
      json.field "callback_rows", scan[:callback_rows]
      json.field "offsets" do
        json.array do
          scan[:offsets].each do |mark, source_offset, count|
            json.array do
              json.number mark
              json.number source_offset
              json.number count
            end
          end
        end
      end
    end
    nil
  end

  def self.write_report(json : JSON::Builder, report : TableReport) : Nil
    json.object do
      json.field "columns", report[:columns]
      json.field "column_types" do
        json.array do
          report[:column_types].each do |name, type|
            json.array { json.string name; json.string type }
          end
        end
      end
      json.field "column_sources" do
        json.array do
          report[:column_sources].each do |name, source, type|
            json.array { json.string name; json.string source; json.string type }
          end
        end
      end
      json.field "part_mark_row_counts", report[:part_mark_row_counts]
      json.field "total_row_count", report[:total_row_count]
      {"full" => report[:full], "first" => report[:first], "middle" => report[:middle],
       "last" => report[:last], "eof" => report[:eof], "candidates" => report[:candidates],
       "one_row_batches" => report[:one_row_batches]}.each do |name, scan|
        json.field name do
          write_scan(json, scan)
        end
      end
    end
    nil
  end

  def self.write_mv_source_report(json : JSON::Builder, report : MvSourceReport) : Nil
    json.object do
      json.field "source_table", report[:source_table]
      json.field "output_path", report[:output_path]
      json.field "callback_count", report[:callback_count]
      json.field "row_count", report[:row_count]
      json.field "keys", report[:keys]
      json.field "values", report[:values]
      json.field "offsets" do
        json.array do
          report[:offsets].each do |mark, source_offset, count|
            json.array { json.number mark; json.number source_offset; json.number count }
          end
        end
      end
    end
    nil
  end

  def self.write_mixed_scan(json : JSON::Builder, scan : MixedScan) : Nil
    json.object do
      json.field "keys", scan[:keys]
      json.field "strings", scan[:strings]
      json.field "offsets" do
        json.array do
          scan[:offsets].each do |part, mark, part_row, source_row, count|
            json.array do
              json.number part
              json.number mark
              json.number part_row
              json.number source_row
              json.number count
            end
          end
        end
      end
    end
    nil
  end

  def self.write_mixed_report(json : JSON::Builder, report : MixedReport) : Nil
    json.object do
      json.field "full" { write_mixed_scan(json, report[:full]) }
      json.field "window" { write_mixed_scan(json, report[:window]) }
      json.field "candidates" { write_mixed_scan(json, report[:candidates]) }
      json.field "schedule_mutated", report[:schedule_mutated]
    end
    nil
  end

  def self.run(args : Array(String)) : Nil
    unless args.size == 3 && args[0] == "roundtrip"
      STDERR.puts "usage: check_compact_typed_w260.cr roundtrip WIDE_PART MANIFEST.json"
      exit(2)
    end

    manifest = JSON.parse(File.read(args[2]))
    raise ArgumentError.new("wrong W260 manifest format") unless manifest["format"].as_s == "compact_typed_w260_manifest_v1"
    catalog_root = manifest["catalog_root"].as_s
    entries = manifest["parts"].as_a
    raise ArgumentError.new("W260 manifest must contain ten Compact entries") unless entries.size == CompactTypedW260Fixture::COMPACT_LABELS.size
    by_label = Hash(String, NamedTuple(table: String, path: String)).new
    entries.each do |entry|
      label = entry["label"].as_s
      raise ArgumentError.new("duplicate or unknown W260 manifest label") unless CompactTypedW260Fixture::COMPACT_LABELS.includes?(label) && !by_label.has_key?(label)
      by_label[label] = {table: entry["table"].as_s, path: File.expand_path(entry["path"].as_s)}
    end
    raise ArgumentError.new("W260 manifest labels differ from sealed matrix") unless by_label.keys.sort == CompactTypedW260Fixture::COMPACT_LABELS.sort
    mv_manifest = manifest["mv_source"].as_h
    mv_label = mv_manifest["label"].as_s
    raise ArgumentError.new("W260 MV source must be the sealed schema-A baseline cell") unless mv_label == "a_mrk3_s0_vbasic"
    mv_target_path = File.expand_path(mv_manifest["target_path"].as_s)

    wide_path = File.expand_path(args[1])
    wide_report = inspect_table(
      CrystalClick::WidePartTable.open_selected_typed([wide_path], CompactTypedW260Fixture::SELECTED_WIDE),
      "wide_control",
      CompactTypedW260Fixture::SELECTED_WIDE,
    )

    compact_reports = Hash(String, Tuple(TableReport, TableReport, NamedTuple(
      values: Hash(String, Array(String)),
      candidate_keys: Array(UInt64),
      candidate_mark_indices: Array(Int32),
      candidate_callback_rows: Array(Int32),
      candidate_filtered_keys: Array(UInt64),
      label: String,
    ))).new
    compact_physical_reports = Hash(String, Array(PhysicalColumnReport)).new
    CompactTypedW260Fixture::COMPACT_LABELS.each do |label|
      entry = by_label[label]
      columns = CompactTypedW260Fixture.columns_for(label)
      direct = CrystalClick::CompactPartTable.open_selected_typed([entry[:path]], columns)
      facade = CrystalClick::TypedPartTable.open_selected_typed([entry[:path]], columns)
      direct_report = inspect_table(direct, label, columns)
      facade_report = inspect_table(facade, label, columns)
      unless direct_report[:full] == facade_report[:full] && direct_report[:middle] == facade_report[:middle]
        raise CrystalClick::CorruptPartError.new("W260 direct Compact and format-neutral typed reports differ for #{label}")
      end
      compact_physical_reports[label] = inspect_physical(entry[:path])
      catalog_values = if CompactTypedW260Fixture::SCHEMA_A_LABELS.includes?(label)
                         CompactTypedW260Fixture::SELECTED_A
                       else
                         CompactTypedW260Fixture::SELECTED_B
                       end
      compact_reports[label] = {direct_report, facade_report, catalog_report(catalog_root, entry[:table], label, catalog_values)}
    end
    physical_two_column = inspect_two_column_physical
    mixed_facade = inspect_mixed_facade(wide_path, by_label["a_mrk3_s0_vbasic"][:path])
    mv_report = mv_source_report(catalog_root, by_label[mv_label][:table], mv_target_path)

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "wide_control" do
          write_report(json, wide_report)
        end
        json.field "compact" do
          json.object do
            CompactTypedW260Fixture::COMPACT_LABELS.each do |label|
              direct, facade, catalog = compact_reports[label]
              json.field label do
                json.object do
                  json.field "direct" { write_report(json, direct) }
                  json.field "typed_facade" { write_report(json, facade) }
                  json.field "catalog" do
                    json.object do
                      json.field "values" do
                        json.object do
                          catalog[:values].keys.sort.each { |column| json.field column, catalog[:values][column] }
                        end
                      end
                      json.field "candidate_keys", catalog[:candidate_keys]
                      json.field "candidate_mark_indices", catalog[:candidate_mark_indices]
                      json.field "candidate_callback_rows", catalog[:candidate_callback_rows]
                      json.field "candidate_filtered_keys", catalog[:candidate_filtered_keys]
                    end
                  end
                end
              end
            end
          end
        end
        json.field "compact_physical" do
          json.object do
            CompactTypedW260Fixture::COMPACT_LABELS.each do |label|
              json.field label do
                json.array do
                  compact_physical_reports[label].each do |entry|
                    json.object do
                      json.field "column", entry[:column]
                      json.field "logical_bytes", entry[:logical_bytes]
                      json.field "shard_bytes", entry[:shard_bytes]
                    end
                  end
                end
              end
            end
          end
        end
        json.field "physical_two_column" do
          json.object do
            json.field "columns", physical_two_column[:columns]
            json.field "logical_bytes", physical_two_column[:logical_bytes]
            json.field "shard_bytes", physical_two_column[:shard_bytes]
          end
        end
        json.field "mixed_typed_facade" do
          write_mixed_report(json, mixed_facade)
        end
        json.field "compact_mv_source" do
          write_mv_source_report(json, mv_report)
        end
      end
    end
    STDOUT << '\n'
    STDOUT.flush
    nil
  end
end

CheckCompactTypedW260.run(ARGV)
