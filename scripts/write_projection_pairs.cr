require "../src/crystal_click"
require "file_utils"

# W289 caller-precomputed mixed-format native fixture generator.
# It writes only fresh part roots beneath the one absolute output root argument.
W289_ROOT_PART_NAME = "all_1_1_0"
W289_PROJECTION     = "by_score"
W289_PARENT_ROWS    = [
  {1_u64, 50_u64, "a\0b"},
  {2_u64, 10_u64, ""},
  {3_u64, 40_u64, "café"},
  {4_u64, 20_u64, "z\0"},
  {5_u64, 60_u64, "é"},
  {6_u64, 30_u64, "hi"},
]
W289_CHILD_ROWS = [
  {2_u64, 10_u64, ""},
  {4_u64, 20_u64, "z\0"},
  {6_u64, 30_u64, "hi"},
  {3_u64, 40_u64, "café"},
  {1_u64, 50_u64, "a\0b"},
  {5_u64, 60_u64, "é"},
]

private def w289_u64_groups(values : Array(UInt64), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
  values.each_slice(rows_per_mark).map do |slice|
    slice.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end.to_a
end

private def w289_string_groups(values : Array(String), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
  values.each_slice(rows_per_mark).map do |slice|
    slice.map { |value| CrystalClick::BinaryValue.string(value) }
  end.to_a
end

private def w289_wide_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::WidePartColumn
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive("UInt64"),
    w289_u64_groups(values, rows_per_mark),
  )
end

private def w289_wide_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::WidePartColumn
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive("String"),
    w289_string_groups(values, rows_per_mark),
  )
end

private def w289_compact_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
  CrystalClick::CompactPartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive("UInt64"),
    w289_u64_groups(values, rows_per_mark),
  )
end

private def w289_compact_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
  CrystalClick::CompactPartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive("String"),
    w289_string_groups(values, rows_per_mark),
  )
end

private def w289_assert_absolute_fresh_root!(root : String) : String
  unless root.starts_with?("/")
    raise ArgumentError.new("W289 output root must be an absolute path")
  end
  if File.symlink?(root)
    raise ArgumentError.new("W289 output root must not be a symlink")
  end
  if File.exists?(root) && (!Dir.exists?(root) || !Dir.empty?(root))
    raise ArgumentError.new("W289 output root must be fresh and empty")
  end
  FileUtils.mkdir_p(root)
  File.realpath(root)
end

if ARGV.size != 1
  STDERR.puts "usage: crystal run scripts/write_projection_pairs.cr -- <absolute-fresh-output-root>"
  exit 2
end

begin
  output_root = w289_assert_absolute_fresh_root!(ARGV[0])
  compact_parent_path = File.join(output_root, "compact_parent_wide_child", W289_ROOT_PART_NAME)
  wide_parent_path = File.join(output_root, "wide_parent_compact_child", W289_ROOT_PART_NAME)
  FileUtils.mkdir_p(File.dirname(compact_parent_path))
  FileUtils.mkdir_p(File.dirname(wide_parent_path))

  parent_ids = W289_PARENT_ROWS.map(&.[0])
  parent_scores = W289_PARENT_ROWS.map(&.[1])
  parent_labels = W289_PARENT_ROWS.map(&.[2])
  child_scores = W289_CHILD_ROWS.map(&.[1])
  child_ids = W289_CHILD_ROWS.map(&.[0])
  child_labels = W289_CHILD_ROWS.map(&.[2])

  # Compact parent id,score,label. The Wide child key is score and its value
  # owners follow the persisted SELECT score,id,label layout.
  wide_child = CrystalClick::WidePartProjection.precomputed(
    W289_PROJECTION,
    "score",
    child_scores.to_unsafe.to_slice(child_scores.size),
    [
      w289_wide_u64("id", child_ids, 3),
      w289_wide_string("label", child_labels, 3),
    ] of CrystalClick::WidePartColumn,
    rows_per_mark: 3,
  )
  compact_parent_projections = [] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
  compact_parent_projections << wide_child
  CrystalClick::CompactPartWriter.write_uint64_columns(
    compact_parent_path,
    "id",
    parent_ids.to_unsafe.to_slice(parent_ids.size),
    [
      w289_compact_u64("score", parent_scores, 2),
      w289_compact_string("label", parent_labels, 2),
    ] of CrystalClick::CompactPartColumn,
    rows_per_mark: 2,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    compress_marks: false,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    projections: compact_parent_projections,
  )

  # Wide parent id,score,label. The Compact child keeps its own MRK4 grid and
  # explicit single-stream String profile, while the parent uses S1.
  compact_child = CrystalClick::CompactPartProjection.precomputed(
    W289_PROJECTION,
    "score",
    child_scores.to_unsafe.to_slice(child_scores.size),
    [
      w289_compact_u64("id", child_ids, 3),
      w289_compact_string("label", child_labels, 3),
    ] of CrystalClick::CompactPartColumn,
    rows_per_mark: 3,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    compress_marks: false,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
  )
  wide_parent_projections = [] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
  wide_parent_projections << compact_child
  CrystalClick::WidePartWriter.write_uint64_columns(
    wide_parent_path,
    "id",
    parent_ids.to_unsafe.to_slice(parent_ids.size),
    [
      w289_wide_u64("score", parent_scores, 2),
      w289_wide_string("label", parent_labels, 2),
    ] of CrystalClick::WidePartColumn,
    rows_per_mark: 2,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    projections: wide_parent_projections,
  )

  [
    {table: "compact_parent_wide_child", parent_path: compact_parent_path, parent_format: "Compact", child_format: "Wide", parent_columns: ["id", "score", "label"], child_columns: ["score", "id", "label"], parent_marks: [2, 2, 2], child_marks: [3, 3], parent_string_profile: "with_size_stream", child_string_profile: "with_size_stream"},
    {table: "wide_parent_compact_child", parent_path: wide_parent_path, parent_format: "Wide", child_format: "Compact", parent_columns: ["id", "score", "label"], child_columns: ["score", "id", "label"], parent_marks: [2, 2, 2], child_marks: [3, 3], parent_string_profile: "with_size_stream", child_string_profile: "single_stream"},
  ].each do |pair|
    child_path = File.join(pair[:parent_path], "#{W289_PROJECTION}.proj")
    unless File.file?(File.join(pair[:parent_path], "columns.txt")) &&
           File.file?(File.join(child_path, "columns.txt"))
      raise CrystalClick::UnsupportedFormatError.new("#{pair[:table]} writer omitted a columns.txt witness")
    end
    puts "PAIR #{pair[:table]} parent=#{pair[:parent_format]} child=#{pair[:child_format]}"
    puts "  parent_path=#{pair[:parent_path]}"
    puts "  child_path=#{child_path}"
    puts "  parent_columns_txt_begin"
    print File.read(File.join(pair[:parent_path], "columns.txt"))
    puts "  parent_columns_txt_end"
    puts "  child_columns_txt_begin"
    print File.read(File.join(child_path, "columns.txt"))
    puts "  child_columns_txt_end"
    puts "  literal_rows=6 parent_grid=#{pair[:parent_marks]} child_grid=#{pair[:child_marks]}"
    puts "  key_and_value_order parent=id,score,label child=score,id,label"
    puts "  string_profiles parent=#{pair[:parent_string_profile]} child=#{pair[:child_string_profile]}"
  end
  puts "status=observed output_root=#{output_root}"
rescue error
  STDERR.puts "status=failed error=#{error.class}: #{error.message}"
  exit 1
end
