require "crystal_tui"
require "./page_source"

module CrystalClick
  module Examples
    # Keep terminal output printable and capped even when metadata or exception
    # messages contain control characters or unexpectedly long text.
    module OfflineTuiDisplayText
      TREE_LABEL_BYTES =  96
      LINE_BYTES       = 512

      def self.printable(value : String, max_bytes : Int32 = LINE_BYTES) : String
        String.build do |output|
          bytes_written = 0
          truncated = false

          value.each_char do |character|
            code = character.ord
            escaped = case code
                      when 0x00
                        "\\0"
                      when 0x09
                        "\\t"
                      when 0x0a
                        "\\n"
                      when 0x0d
                        "\\r"
                      when 0x01..0x1f, 0x7f
                        "\\x#{code.to_s(16).upcase.rjust(2, '0')}"
                      when 0x80..0x9f
                        "\\u{#{code.to_s(16).upcase}}"
                      when 0x061c, 0x200e..0x200f, 0x202a..0x202e, 0x2066..0x2069
                        "\\u{#{code.to_s(16).upcase.rjust(4, '0')}}"
                      else
                        character.to_s
                      end

            if bytes_written + escaped.bytesize > max_bytes
              truncated = true
              break
            end

            output << escaped
            bytes_written += escaped.bytesize
          end

          output << "…" if truncated && bytes_written + 3 <= max_bytes
        end
      end
    end

    # Minimal adapter between OfflineCatalog and crystal_tui's Tree widget.
    class OfflineBrowserNodeData
      getter database : String?
      getter table : String?
      property loaded : Bool

      def initialize(@database : String? = nil, @table : String? = nil, @loaded : Bool = false)
      end

      def database_node? : Bool
        !@database.nil? && @table.nil?
      end

      def table_node? : Bool
        !@database.nil? && !@table.nil?
      end
    end

    # Renders only the current owned page. Borrowed reader slices are formatted
    # and copied by OfflinePageSource before they reach this widget.
    class OfflinePagePane < Tui::Widget
      MAX_PAGE_ROWS             = OfflinePageSource::MAX_PAGE_ROWS
      MAX_OMITTED_COLUMN_LABELS =  4
      MAX_OMITTED_COLUMN_BYTES  = 48
      MAX_ERROR_BYTES           = OfflineTuiDisplayText::LINE_BYTES

      getter page : OfflinePage?
      getter error_message : String?

      @source : OfflinePageSource?
      @page_rows : Int32
      @table_label : String?
      @candidate_count : Int32?
      @omitted_columns : Array(String) = [] of String
      @omitted_column_count : Int32 = 0
      @notice : String = "Activate a database, then a table, to open a physical MergeTree page."

      def initialize(@page_rows : Int32 = MAX_PAGE_ROWS)
        super("offline-page")
        raise BoundsError.new("page row count is out of range") if @page_rows <= 0 || @page_rows > MAX_PAGE_ROWS
        @focusable = true
      end

      # Clear first so a failed table switch can never leave the previous
      # table's page visible beside an error for the new selection.
      def clear(message : String) : Nil
        @source = nil
        @page = nil
        @error_message = nil
        @table_label = nil
        @candidate_count = nil
        @omitted_columns.clear
        @omitted_column_count = 0
        @notice = message
        mark_dirty!
      end

      def show_error(message : String) : Nil
        @page = nil
        @error_message = OfflineTuiDisplayText.printable(message, MAX_ERROR_BYTES)
        @notice = ""
        mark_dirty!
      end

      def open_table(table : OfflineTable, database_name : String, table_name : String) : Nil
        clear("Opening #{database_name}.#{table_name}...")
        @table_label = "#{database_name}.#{table_name}"

        begin
          @candidate_count = table.part_candidates.size
          selected = [] of OfflineColumn
          table.columns.each do |column|
            if !column.alias_column && WidePart.supports_typed_type?(column.type) && selected.size < WidePartTable::MAX_COLUMNS
              selected << column
            else
              @omitted_column_count += 1
              if @omitted_columns.size < MAX_OMITTED_COLUMN_LABELS
                name = OfflineTuiDisplayText.printable(column.name, MAX_OMITTED_COLUMN_BYTES)
                type = OfflineTuiDisplayText.printable(column.type, MAX_OMITTED_COLUMN_BYTES)
                @omitted_columns << "#{name} (#{type})"
              end
            end
          end

          if selected.empty?
            raise UnsupportedFormatError.new("table has no directly supported non-ALIAS columns")
          end

          source = OfflinePageSource.new(table, selected.map(&.name), @page_rows)
          @source = source
          @page = source.load(0_u64)
          @notice = ""
        rescue exception : Exception
          show_error(exception.message || exception.class.name)
        end
        mark_dirty!
      end

      def on_event(event : Tui::Event) : Bool
        return false unless focused?
        return false unless key = event.as?(Tui::KeyEvent)

        if key.matches?("pagedown")
          page = @page
          if page && page.start_row + @page_rows.to_u64 < page.total_rows
            load_page(page.start_row + @page_rows.to_u64)
          end
          return true
        elsif key.matches?("pageup")
          page = @page
          if page && page.start_row > 0
            load_page(page.start_row > @page_rows.to_u64 ? page.start_row - @page_rows.to_u64 : 0_u64)
          end
          return true
        end

        false
      end

      def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
        return unless visible?
        return if @rect.empty?

        x = @rect.x
        y = @rect.y
        draw_line(buffer, clip, x, y, @table_label ? "TABLE #{@table_label}" : "OFFLINE TABLE PAGE")
        y += 1
        draw_line(buffer, clip, x, y, "Physical part/mark order; candidates are not server Active parts.")
        y += 1

        if count = @candidate_count
          draw_line(buffer, clip, x, y, "#{count} physical candidates (not server Active)")
        else
          draw_line(buffer, clip, x, y, focused? ? "Page pane focused; Tab returns to tree." : "Tab moves focus between tree and page.")
        end
        y += 1

        if @omitted_column_count > 0
          omitted = @omitted_columns.join(", ")
          if @omitted_column_count > @omitted_columns.size
            more = @omitted_column_count - @omitted_columns.size
            omitted += ", +#{more} more"
          end
          draw_line(buffer, clip, x, y, "Omitted #{@omitted_column_count} columns: #{omitted}")
          y += 1
        end

        if error = @error_message
          draw_line(buffer, clip, x, y, "ERROR: #{error}")
          return
        end

        page = @page
        unless page
          draw_line(buffer, clip, x, y, @notice) unless @notice.empty?
          return
        end

        page_end = page.rows.empty? ? page.start_row : page.start_row + page.rows.size.to_u64 - 1
        draw_line(buffer, clip, x, y, "offset #{page.start_row}..#{page_end} of #{page.total_rows} physical rows")
        y += 1
        draw_line(buffer, clip, x, y, page.column_names.join(" | "))
        y += 1

        if page.rows.empty?
          draw_line(buffer, clip, x, y, "(empty table)")
        else
          page.rows.each_with_index do |row, index|
            break if y + index >= @rect.bottom
            draw_line(buffer, clip, x, y + index, "#{page.start_row + index}: #{row.join(" | ")}")
          end
        end
      end

      private def load_page(start_row : UInt64) : Nil
        @page = nil
        @error_message = nil
        @notice = "Loading physical rows at offset #{start_row}..."
        begin
          source = @source || raise(UnsupportedFormatError.new("no table is selected"))
          @page = source.load(start_row)
          @notice = ""
        rescue exception : Exception
          show_error(exception.message || exception.class.name)
        end
        mark_dirty!
      end

      private def draw_line(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32, text : String) : Nil
        return unless clip.contains?(x, y)

        cursor_x = x
        OfflineTuiDisplayText.printable(text).each_char do |character|
          break if cursor_x >= @rect.right || cursor_x >= clip.right
          width = buffer.set(cursor_x, y, character)
          cursor_x += width if width > 0
        end
      end
    end

    # Optional example app: lazily lists table names and pages one physical
    # MergeTree table at a time. This does not model ClickHouse server state.
    class OfflineTableBrowserApp < Tui::App
      getter tree : Tui::Tree(OfflineBrowserNodeData)
      getter page_pane : OfflinePagePane
      getter quit_requested : Bool = false

      @catalog : OfflineCatalog

      def initialize(@catalog : OfflineCatalog, page_rows : Int32 = OfflinePagePane::MAX_PAGE_ROWS)
        super()
        @tree = Tui::Tree(OfflineBrowserNodeData).new("offline-tree")
        @tree.show_root = false
        root = Tui::Tree::Node(OfflineBrowserNodeData).new(OfflineBrowserNodeData.new, "Databases")
        root.expanded = true
        @catalog.database_names.each do |database_name|
          label = OfflineTuiDisplayText.printable(database_name, OfflineTuiDisplayText::TREE_LABEL_BYTES)
          root.add(OfflineBrowserNodeData.new(database_name), label)
        end
        @tree.root = root
        @page_pane = OfflinePagePane.new(page_rows)
        @tree.on_activate do |node|
          data = node.data
          if database_name = data.database
            if table_name = data.table
              @page_pane.clear("Opening #{database_name}.#{table_name}...")
              begin
                table = @catalog.table(database_name, table_name)
                @page_pane.open_table(table, database_name, table_name)
              rescue exception : Exception
                @page_pane.show_error(exception.message || exception.class.name)
              end
            elsif data.database_node? && !data.loaded
              @page_pane.clear("Loading tables from #{database_name}...")
              begin
                table_names = @catalog.table_names(database_name)
                staged_nodes = table_names.map do |table_name|
                  label = OfflineTuiDisplayText.printable(table_name, OfflineTuiDisplayText::TREE_LABEL_BYTES)
                  Tui::Tree::Node(OfflineBrowserNodeData).new(
                    OfflineBrowserNodeData.new(database_name, table_name),
                    label
                  )
                end
                # Build a replacement child array before publishing it. If
                # enumeration or staging fails, the live tree remains empty;
                # on success children become visible as one assignment.
                staged_nodes.each { |table_node| table_node.parent = node }
                node.children = node.children + staged_nodes
                data.loaded = true
                node.expand
                @page_pane.clear("Choose a table under #{database_name}.")
              rescue exception : Exception
                @page_pane.show_error(exception.message || exception.class.name)
              end
            end
          end
        end
      end

      def compose : Array(Tui::Widget)
        panes = Tui::HBox.new("offline-browser-panes")
        panes.add_child(@tree)
        panes.add_child(@page_pane)
        [panes] of Tui::Widget
      end

      def on_mount : Nil
        super
        @tree.focus
      end

      # App#on_event is not reached for keys while a child owns focus, so q must
      # be captured before key dispatch just like Tab and Ctrl+C.
      def on_capture(event : Tui::Event) : Bool
        if key = event.as?(Tui::KeyEvent)
          if key.matches?("q")
            @quit_requested = true
            quit
            return true
          end
        end

        super
      end
    end
  end
end
