require "../../../spec/spec_helper"
require "../page_source"
require "../offline_table_browser_widget"

OFFLINE_TUI_FIXTURE          = File.expand_path("../../../test/fixtures/public/wide_string_nullable/part", __DIR__)
OFFLINE_TUI_DATABASE_UUID    = "8d908d2a-589c-4f7b-84a4-0c6730dfcbac"
OFFLINE_TUI_TABLE_UUID       = "8db445cf-0f66-4bfa-8544-275d43fa4110"
OFFLINE_TUI_UNSUPPORTED_UUID = "9f7d4128-34e4-4fb2-9321-574b3f038691"

def with_offline_tui_catalog(&)
  root = File.tempname("crystal-click-offline-tui-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", OFFLINE_TUI_DATABASE_UUID[0, 3], OFFLINE_TUI_DATABASE_UUID)
  table_path = File.join(root, "store", OFFLINE_TUI_TABLE_UUID[0, 3], OFFLINE_TUI_TABLE_UUID)
  unsupported_path = File.join(root, "store", OFFLINE_TUI_UNSUPPORTED_UUID[0, 3], OFFLINE_TUI_UNSUPPORTED_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  FileUtils.mkdir_p(unsupported_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{OFFLINE_TUI_DATABASE_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_TUI_TABLE_UUID}'\n(\n    `label` String,\n    `maybe_u64` Nullable(UInt64)\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(
      File.join(database_path, "unsupported.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_TUI_UNSUPPORTED_UUID}'\n(\n    `payload` Array(Float64)\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(OFFLINE_TUI_FIXTURE, File.join(table_path, "all_1_1_0"))
    File.write(File.join(unsupported_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(unsupported_path, "detached"))
    yield CrystalClick::OfflineCatalog.open(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::Examples::OfflineTableBrowserApp do
  it "loads table names on database activation and pages forward and backward" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog, page_rows: 2)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      harness.render

      database_node = app.tree.selected_node.not_nil!
      database_node.label.should eq("lab")
      database_node.children.should be_empty

      harness.press(Tui::Key::Enter)
      database_node.children.map(&.label).should eq(["events", "unsupported"])
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)

      first_page = harness.render_text
      first_page.should contain("physical candidates")
      first_page.should contain("not server Active")
      first_page.should contain("\"alpha\"")

      harness.press(Tui::Key::Tab)
      harness.press(Tui::Key::PageDown)
      second_page = harness.render_text
      second_page.should contain("physical window [2, 4)")
      second_page.should contain("\"tail\"")

      harness.press(Tui::Key::PageUp)
      previous_page = harness.render_text
      previous_page.should contain("physical window [0, 2)")
      previous_page.should contain("\"alpha\"")

      harness.press(Tui::Key::Tab)
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)
      failed_switch = harness.render_text
      failed_switch.should contain("ERROR: table has no directly supported")
      app.page_pane.error_message.should eq("table has no directly supported non-ALIAS columns")
      failed_switch.should_not contain("\"alpha\"")
      app.page_pane.page.should be_nil

      harness.type('q')
      app.quit_requested.should be_true
    end
  end

  it "filters within physical windows, labels sparse matches, and preserves state on invalid input" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog, page_rows: 2)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      harness.render

      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Tab)

      harness.type('/')
      harness.type_string("label=tail")
      harness.press(Tui::Key::Enter)

      first_window = app.page_pane.page.not_nil!
      first_window.start_row.should eq(0_u64)
      first_window.end_row.should eq(2_u64)
      first_window.rows.should be_empty
      harness.render_text.should contain("no matches")

      # An empty filtered window is not EOF: PageDown advances by the physical
      # end offset rather than by the number of displayed matches.
      harness.press(Tui::Key::PageDown)
      second_window = app.page_pane.page.not_nil!
      second_window.start_row.should eq(2_u64)
      second_window.end_row.should eq(4_u64)
      second_window.row_offsets.should eq([3_u64])
      second_window.rows.size.should eq(1)
      harness.render_text.should contain("3: \"tail\"")

      # Unsupported/invalid input reports an error without replacing the last
      # accepted filter or moving the visible physical page.
      harness.type('/')
      harness.press(Tui::Key::Home)
      harness.ctrl('k')
      harness.type_string("maybe_u64=1")
      harness.press(Tui::Key::Enter)
      app.page_pane.filter_error.should_not be_nil
      app.page_pane.equality_filter.not_nil!.column.should eq("label")
      app.page_pane.page.not_nil!.start_row.should eq(2_u64)
      app.page_pane.page.not_nil!.row_offsets.should eq([3_u64])
      harness.render_text.should contain("FILTER ERROR")
      harness.press(Tui::Key::Escape)
      app.page_pane.page.not_nil!.start_row.should eq(2_u64)
      app.page_pane.page.not_nil!.rows[0][0].should contain("tail")

      harness.type('c')
      app.page_pane.equality_filter.should be_nil
      app.page_pane.page.not_nil!.start_row.should eq(0_u64)
      app.page_pane.page.not_nil!.rows.size.should eq(2)

      # Empty String is a real equality value, not a missing value. Split only
      # at the first '=' and preserve whitespace and later '=' characters.
      harness.type('/')
      harness.type_string("label=")
      harness.press(Tui::Key::Enter)
      app.page_pane.equality_filter.not_nil!.value.should eq("")
      app.page_pane.page.not_nil!.row_offsets.should eq([0_u64])
      app.page_pane.page.not_nil!.rows.should eq([["\"\"", "0"]])

      harness.type('/')
      harness.press(Tui::Key::Home)
      harness.ctrl('k')
      harness.type_string("label= tail=value ")
      harness.press(Tui::Key::Enter)
      app.page_pane.equality_filter.not_nil!.value.should eq(" tail=value ")
    end
  end

  it "keeps q and Tab inside filter edit mode and rejects invisible or unsafe text" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog, page_rows: 2)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      harness.render

      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Tab)
      harness.type('/')

      harness.type('q')
      app.page_pane.filter_input.value.should eq("q")
      app.quit_requested.should be_false
      harness.press(Tui::Key::Tab)
      app.page_pane.filter_input.focused?.should be_true
      harness.press(Tui::Key::Tab, Tui::Modifiers::Shift)
      app.page_pane.filter_input.focused?.should be_true
      harness.press(Tui::Key::Escape)
      app.quit_requested.should be_false
      app.page_pane.equality_filter.should be_nil
      app.page_pane.filter_error.should be_nil

      harness.type('/')
      app.handle_event(Tui::PasteEvent.new("x" * CrystalClick::Examples::OfflinePagePane::MAX_FILTER_SOURCE_BYTES))
      app.page_pane.filter_input.value.bytesize.should eq(CrystalClick::Examples::OfflinePagePane::MAX_FILTER_SOURCE_BYTES)
      harness.press(Tui::Key::Home)
      harness.ctrl('k')
      app.page_pane.filter_input.value.should eq("")

      app.handle_event(Tui::PasteEvent.new("x" * (CrystalClick::Examples::OfflinePagePane::MAX_FILTER_SOURCE_BYTES + 1)))
      app.page_pane.filter_input.value.should eq("")
      app.page_pane.filter_error.not_nil!.should contain("exceeds")

      app.handle_event(Tui::PasteEvent.new("label=bad\u202Evalue"))
      app.page_pane.filter_input.value.should eq("")
      app.page_pane.filter_error.should_not be_nil

      {"\u200B", "\u2060", "\u2028", "\u2029", "\u180B", "\uFE0F", "\uFFFA"}.each do |invisible|
        app.handle_event(Tui::PasteEvent.new("label=bad#{invisible}hidden"))
        app.page_pane.filter_input.value.should eq("")
        app.page_pane.filter_error.should_not be_nil
      end

      harness.press(Tui::Key::Escape)
      app.page_pane.filter_error.should be_nil

      # KeyEvent paths must not retain zero-width characters either. Some
      # terminals mark these non-printable before the app capture guard sees
      # them; in either case the input stays clear.
      harness.type('/')
      {'\u200B', '\u2060', '\u2028', '\u2029', '\u180B', '\uFE0F', '\uFFFA'}.each do |invisible|
        harness.type(invisible)
      end
      app.page_pane.filter_input.value.should eq("")
      harness.press(Tui::Key::Escape)

      rendered = harness.render_text
      {"\u202E", "\u200B", "\u2060", "\u2028", "\u2029", "\u180B", "\uFE0F", "\uFFFA"}.each do |invisible|
        rendered.includes?(invisible).should be_false
      end

      printable = CrystalClick::Examples::OfflineTuiDisplayText.printable(
        "a\u00ADb\u034Fc\u061Cd\u180Ee\u200Bf\u200Fg\u202Ah\u2060i\uFEFFj\u2028k\u2029l\u180Bm\uFE0Fn\uFFFA"
      )
      printable.should contain("\\u{00AD}")
      printable.should contain("\\u{034F}")
      printable.should contain("\\u{061C}")
      printable.should contain("\\u{180E}")
      printable.should contain("\\u{200B}")
      printable.should contain("\\u{200F}")
      printable.should contain("\\u{202A}")
      printable.should contain("\\u{2060}")
      printable.should contain("\\u{FEFF}")
      printable.should contain("\\u{2028}")
      printable.should contain("\\u{2029}")
      printable.should contain("\\u{180B}")
      printable.should contain("\\u{FE0F}")
      printable.should contain("\\u{FFFA}")
      printable.should_not contain("\\u0301")
      CrystalClick::Examples::OfflineTuiDisplayText.printable("e\u0301").should eq("e\u0301")
    end
  end

  it "clears a table's filter when switching to another table" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog, page_rows: 2)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      harness.render

      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)
      harness.press(Tui::Key::Tab)
      harness.type('/')
      harness.type_string("label=tail")
      harness.press(Tui::Key::Enter)
      app.page_pane.equality_filter.should_not be_nil

      harness.press(Tui::Key::Tab)
      harness.press(Tui::Key::Down)
      harness.press(Tui::Key::Enter)
      app.page_pane.equality_filter.should be_nil
      app.page_pane.page.should be_nil
      harness.render_text.should contain("ERROR: table has no directly supported")
    end
  end

  it "publishes database children only after successful enumeration and permits retry" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      harness.render

      database_node = app.tree.selected_node.not_nil!
      database_path = File.join(catalog.root, "store", OFFLINE_TUI_DATABASE_UUID[0, 3], OFFLINE_TUI_DATABASE_UUID)
      bad_metadata = File.join(database_path, "zz_bad.sql")
      File.symlink("events.sql", bad_metadata)
      harness.press(Tui::Key::Enter)

      database_node.children.should be_empty
      database_node.data.loaded.should be_false
      harness.render_text.should contain("ERROR: table DDL is a symbolic link")

      File.delete(bad_metadata)
      harness.press(Tui::Key::Enter)
      database_node.children.map(&.label).should eq(["events", "unsupported"])
      database_node.data.loaded.should be_true
    end
  end

  it "sanitizes and caps displayed metadata and retained error text" do
    with_offline_tui_catalog do |catalog|
      app = CrystalClick::Examples::OfflineTableBrowserApp.new(catalog)
      harness = Tui::Testing::Harness.new(app, 100, 20)
      table = catalog.table("lab", "events")

      app.page_pane.open_table(table, "lab\n\u001b[31m\u202e", "events")
      title = harness.render_text
      title.should contain("TABLE lab\\n\\x1B[31m\\u{202E}.events")
      title.includes?("\u001b").should be_false
      title.includes?("\u202e").should be_false

      app.page_pane.show_error("failed\n\u001b[31m\u202e")
      app.page_pane.error_message.should eq("failed\\n\\x1B[31m\\u{202E}")
      error = harness.render_text
      error.should contain("ERROR: failed\\n\\x1B[31m\\u{202E}")
      error.includes?("\u001b").should be_false
      error.includes?("\u202e").should be_false

      app.page_pane.show_error("x" * 600)
      app.page_pane.error_message.not_nil!.bytesize.should be <= CrystalClick::Examples::OfflineTuiDisplayText::LINE_BYTES
    end
  end
end
