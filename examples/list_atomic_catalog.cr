require "../src/crystal_click"

module ListAtomicCatalogExample
  extend self

  def usage : NoReturn
    STDERR.puts "usage: crystal run examples/list_atomic_catalog.cr -- CLICKHOUSE_DATA_ROOT"
    exit 64
  end

  def run(args : Array(String)) : Nil
    usage unless args.size == 1

    catalog = CrystalClick::OfflineCatalog.open(args[0])
    catalog.databases.each do |database|
      puts "DATABASE #{database.name}"

      database.tables.each do |table|
        label = table.kind == :materialized_view ? "MATERIALIZED VIEW" : "TABLE"
        puts "  #{label} #{table.name} (engine: #{table.engine})"
        table.columns.each do |column|
          puts "    COLUMN #{column.name}: #{column.type}"
        end
        table.projections.each do |projection|
          puts "    PROJECTION #{projection.name}"
        end

        if table.kind == :materialized_view
          puts "    PHYSICAL PART CANDIDATES: unavailable for a metadata-only view"
        elsif table.engine == "MergeTree"
          puts "    PHYSICAL PART CANDIDATES (server Active state is unknown):"
          candidates = table.part_candidates
          if candidates.empty?
            puts "      (none)"
          else
            candidates.each do |candidate|
              puts "      #{candidate.name}\trows=#{candidate.row_count}"
            end
          end
        else
          puts "    PHYSICAL PART CANDIDATES: unavailable for this engine"
        end
      end
    end
  rescue ex : Exception
    STDERR.puts "catalog inventory failed: #{ex.message}"
    exit 1
  end
end

ListAtomicCatalogExample.run(ARGV)
