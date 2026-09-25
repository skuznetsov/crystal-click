require "crystal_tui"
require "./page_source"

module CrystalClick
  module Examples
    # Keep terminal output printable and capped even when metadata or exception
    # messages contain control characters or unexpectedly long text.
    module OfflineTuiDisplayText
      TREE_LABEL_BYTES =  96
      LINE_BYTES       = 512

      # Escape format/invisible controls that can hide, reorder, or split filter text:
      # U+00AD, U+034F, U+061C, U+180B..U+180E, U+200B..U+200F, U+2028..U+202E,
      # U+2060..U+206F, U+FE00..U+FE0F, U+FEFF, and U+FFF9..U+FFFB.
      # Ordinary combining accents remain intact; this is not a general Unicode filter.
      def self.invisible_or_format_codepoint?(code : Int32) : Bool
        code == 0x00ad || code == 0x034f || code == 0x061c ||
          (0x180b..0x180e).includes?(code) || (0x200b..0x200f).includes?(code) ||
          (0x2028..0x202e).includes?(code) || (0x2060..0x206f).includes?(code) ||
          (0xfe00..0xfe0f).includes?(code) || code == 0xfeff ||
          (0xfff9..0xfffb).includes?(code)
      end

      def self.printable(value : String, max_bytes : Int32 = LINE_BYTES) : String
        String.build do |output|
          bytes_written = 0
          truncated = false

          value.each_char do |character|
            code = character.ord
            escaped = if invisible_or_format_codepoint?(code)
                        "\\u{#{code.to_s(16).upcase.rjust(4, '0')}}"
                      else
                        case code
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
                        else
                          character.to_s
                        end
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
      MAX_FILTER_SOURCE_BYTES   = 512

      getter page : OfflinePage?
      getter error_message : String?
      getter filter_error : String?
      getter filter_input : Tui::Input
      getter equality_filter : OfflineEqualityFilter?

      @source : OfflinePageSource?
      @page_rows : Int32
      @table_label : String?
      @candidate_count : Int32?
      @omitted_columns : Array(String) = [] of String
      @omitted_column_count : Int32 = 0
      @notice : String = "Activate a database, then a table, to open a physical MergeTree page."
      @filterable_columns : Hash(String, String) = Hash(String, String).new
      @filter_expression : String?
      @filter_editing : Bool = false

      def initialize(@page_rows : Int32 = MAX_PAGE_ROWS)
        super("offline-page")
        raise BoundsError.new("page row count is out of range") if @page_rows <= 0 || @page_rows > MAX_PAGE_ROWS
        @focusable = true
        @filter_input = Tui::Input.new(placeholder: "column=value", id: "offline-filter-input")
        @filter_input.visible = false
        @filter_input.on_submit { |query| apply_filter(query) }
        add_child(@filter_input)
      end

      def filter_editing? : Bool
        @filter_editing
      end

      def begin_filter_edit : Nil
        return unless @source && @page

        @filter_error = nil
        @filter_input.value = @filter_expression || ""
        @filter_editing = true
        @filter_input.visible = true
        @filter_input.focus
        mark_dirty!
      end

      def cancel_filter_edit : Nil
        return unless @filter_editing

        @filter_editing = false
        @filter_input.visible = false
        @filter_input.blur
        @filter_error = nil
        focus
        mark_dirty!
      end

      def reject_filter_input(message : String) : Nil
        @filter_error = OfflineTuiDisplayText.printable(message, MAX_ERROR_BYTES)
        mark_dirty!
      end

      def input_within_limit?(additional_bytes : Int32 = 0) : Bool
        @filter_input.value.bytesize <= MAX_FILTER_SOURCE_BYTES - additional_bytes
      end

      def clear_filter : Nil
        source = @source
        unless source
          @filter_error = nil
          return
        end

        begin
          page = source.load(0_u64)
          @equality_filter = nil
          @filter_expression = nil
          @page = page
          @filter_error = nil
          @error_message = nil
          @notice = ""
        rescue exception : Exception
          reject_filter_input(exception.message || exception.class.name)
        end
        mark_dirty!
      end

      # Clear first so a failed table switch can never leave the previous
      # table's page visible beside an error for the new selection.
      def clear(message : String) : Nil
        @source = nil
        @page = nil
        @error_message = nil
        @filter_error = nil
        @equality_filter = nil
        @filter_expression = nil
        @filterable_columns.clear
        @filter_editing = false
        @filter_input.visible = false
        @filter_input.value = ""
        @filter_input.blur
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
              if column.type == "String" || column.type == "UInt64"
                @filterable_columns[column.name] = column.type
              end
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
          if page && page.end_row < page.total_rows
            load_page(page.end_row)
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
          candidate_status = "#{count} physical candidates (not server Active)"
          if focused?
            candidate_status += "; / filter, c clear, Tab tree"
          end
          draw_line(buffer, clip, x, y, candidate_status)
        else
          focus_status = focused? ? "Page pane focused; / filter, c clear, Tab returns to tree." : "Tab moves focus between tree and page."
          draw_line(buffer, clip, x, y, focus_status)
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

        if @filter_input.visible?
          draw_line(buffer, clip, x, y, "Filter column=value; Enter apply, Esc cancel; Tab stays in filter.")
          y += 1
          @filter_input.rect = Tui::Rect.new(x, y, @rect.width, 1)
          if input_clip = clip.intersect(@filter_input.rect)
            @filter_input.render(buffer, input_clip)
          end
          y += 1
        elsif expression = @filter_expression
          draw_line(buffer, clip, x, y, "FILTER: #{expression}")
          y += 1
        end

        if filter_error = @filter_error
          draw_line(buffer, clip, x, y, "FILTER ERROR: #{filter_error}")
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

        draw_line(buffer, clip, x, y, "physical window [#{page.start_row}, #{page.end_row}) of #{page.total_rows} rows")
        y += 1
        draw_line(buffer, clip, x, y, page.column_names.join(" | "))
        y += 1

        if page.rows.empty?
          empty_message = if page.total_rows == 0
                            "(empty table)"
                          elsif @equality_filter
                            "(no matches in this physical window)"
                          else
                            "(empty page)"
                          end
          draw_line(buffer, clip, x, y, empty_message)
        else
          page.rows.each_with_index do |row, index|
            break if y + index >= @rect.bottom
            draw_line(buffer, clip, x, y + index, "#{page.row_offsets[index]}: #{row.join(" | ")}")
          end
        end
      end

      private def load_page(start_row : UInt64) : Nil
        @page = nil
        @error_message = nil
        @notice = "Loading physical rows at offset #{start_row}..."
        begin
          source = @source || raise(UnsupportedFormatError.new("no table is selected"))
          @page = source.load(start_row, @equality_filter)
          @notice = ""
        rescue exception : Exception
          show_error(exception.message || exception.class.name)
        end
        mark_dirty!
      end

      private def apply_filter(query : String) : Nil
        source = @source || begin
          reject_filter_input("no table is selected")
          return
        end

        begin
          equality = parse_filter(query)
          page = source.load(0_u64, equality)
          @equality_filter = equality
          @filter_expression = query.dup
          @page = page
          @filter_error = nil
          @error_message = nil
          @notice = ""
          @filter_editing = false
          @filter_input.visible = false
          @filter_input.blur
          focus
        rescue exception : Exception
          reject_filter_input(exception.message || exception.class.name)
        end
        mark_dirty!
      end

      private def parse_filter(query : String) : OfflineEqualityFilter
        separator = query.index('=') || raise(ArgumentError.new("filter syntax must be column=value"))
        column = query.byte_slice(0, separator) || ""
        value = query.byte_slice(separator + 1, query.bytesize - separator - 1) || ""
        raise ArgumentError.new("filter column is empty") if column.empty?

        type = @filterable_columns[column]? || raise(ArgumentError.new("column is not a directly selected String or UInt64"))
        case type
        when "String"
          OfflineEqualityFilter.new(column, value)
        when "UInt64"
          unless !value.empty? && value.each_char.all? { |character| character >= '0' && character <= '9' }
            raise ArgumentError.new("UInt64 filter value must be unsigned decimal")
          end
          parsed = value.to_u64?(whitespace: false) || raise(ArgumentError.new("UInt64 filter value is out of range"))
          OfflineEqualityFilter.new(column, parsed)
        else
          raise ArgumentError.new("column is not a directly selected String or UInt64")
        end
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

      # App#on_event is not reached for keys while a child owns focus, so q is
      # captured here except while the filter input owns the keyboard.
      def on_capture(event : Tui::Event) : Bool
        if key = event.as?(Tui::KeyEvent)
          if @page_pane.filter_editing?
            if key.matches?("escape")
              @page_pane.cancel_filter_edit
              return true
            elsif key.matches?("tab") || key.matches?("shift+tab")
              # Editing is intentionally modal: focus cannot escape the
              # uncommitted predicate until Enter applies or Escape cancels.
              return true
            end

            if key.printable? && !filter_editing_shortcut?(key) && (character = key.char)
              unless safe_filter_character?(character)
                @page_pane.reject_filter_input("filter input contains an unsafe terminal or direction-control character")
                return true
              end
              if !@page_pane.input_within_limit?(character.bytesize)
                @page_pane.reject_filter_input("filter input exceeds #{OfflinePagePane::MAX_FILTER_SOURCE_BYTES} source bytes")
                return true
              end
            end
          elsif key.matches?("q")
            @quit_requested = true
            quit
            return true
          elsif key.matches?("/") && @page_pane.focused?
            @page_pane.begin_filter_edit
            return true
          elsif key.matches?("c") && @page_pane.focused?
            @page_pane.clear_filter
            return true
          end
        elsif paste = event.as?(Tui::PasteEvent)
          if @page_pane.filter_editing?
            if paste.text.bytesize > OfflinePagePane::MAX_FILTER_SOURCE_BYTES ||
               !@page_pane.input_within_limit?(paste.text.bytesize)
              @page_pane.reject_filter_input("filter input exceeds #{OfflinePagePane::MAX_FILTER_SOURCE_BYTES} source bytes")
              return true
            end
            unless safe_filter_text?(paste.text)
              @page_pane.reject_filter_input("filter input contains an unsafe terminal or direction-control character")
              return true
            end
          end
        end

        super
      end

      private def safe_filter_text?(text : String) : Bool
        text.each_char.all? { |character| safe_filter_character?(character) }
      end

      private def filter_editing_shortcut?(key : Tui::KeyEvent) : Bool
        key.matches?("ctrl+a") || key.matches?("ctrl+b") || key.matches?("ctrl+e") ||
          key.matches?("ctrl+f") || key.matches?("ctrl+k") || key.matches?("ctrl+u") ||
          key.matches?("alt+b") || key.matches?("alt+d") || key.matches?("alt+f")
      end

      private def safe_filter_character?(character : Char) : Bool
        code = character.ord
        return false if code <= 0x1f || (0x7f..0x9f).includes?(code)
        return false if OfflineTuiDisplayText.invisible_or_format_codepoint?(code)

        true
      end
    end
  end
end
