require "crystal_tui"
require "../../src/crystal_click"
require "./offline_table_browser_widget"

if ARGV.size != 1
  STDERR.puts "Usage: crystal run examples/offline_tui/main.cr -- <immutable-clickhouse-data-root>"
  exit(2)
end

begin
  catalog = CrystalClick::OfflineCatalog.open(ARGV[0])
  CrystalClick::Examples::OfflineTableBrowserApp.new(catalog).run
rescue exception : Exception
  message = exception.message || exception.class.name
  STDERR.puts "offline TUI: #{CrystalClick::Examples::OfflineTuiDisplayText.printable(message)}"
  exit(1)
end
