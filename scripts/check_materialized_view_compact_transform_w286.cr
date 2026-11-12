require "./support/materialized_view_compact_transform_w286_fixture"

module CheckMaterializedViewCompactTransformW286
  extend self

  def run(args : Array(String)) : Nil
    unless args.size == 6
      STDERR.puts "usage: materialized-view-compact-transform-w286-helper CATALOG_ROOT SOURCE_PART_NAME OUTPUT_PART_NAME mrk3|mrk4 s0|s1 publish|refuse"
      exit(2)
    end

    report = MaterializedViewCompactTransformW286Fixture.run(
      args[0], args[1], args[2], args[3], args[4], args[5],
    )
    puts report.to_json
  rescue error
    STDERR.puts "W286 helper failed: #{error.class}: #{error.message}"
    exit(1)
  end
end

CheckMaterializedViewCompactTransformW286.run(ARGV)
