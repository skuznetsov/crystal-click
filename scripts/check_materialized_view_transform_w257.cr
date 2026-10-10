require "./support/materialized_view_transform_w257_fixture"

module CheckMaterializedViewTransformW257
  extend self

  def run(args : Array(String)) : Nil
    unless args.size == 3
      STDERR.puts "usage: materialized-view-transform-w257-helper CATALOG_ROOT SOURCE_PART_NAME OUTPUT_PART_NAME"
      exit(2)
    end

    report = MaterializedViewTransformW257Fixture.run(args[0], args[1], args[2])
    puts report.to_json
  rescue error
    STDERR.puts "W257 helper failed: #{error.class}: #{error.message}"
    exit(1)
  end
end

CheckMaterializedViewTransformW257.run(ARGV)
