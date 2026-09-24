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
    catalog.database_names.each do |database_name|
      puts "DATABASE #{database_name}"

      catalog.table_names(database_name).each do |table_name|
        table = catalog.table(database_name, table_name)
        puts "  TABLE #{table.name} (engine: #{table.engine})"
        table.columns.each do |column|
          puts "    COLUMN #{column.name}: #{column.type}"
        end

        if table.engine == "MergeTree"
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
