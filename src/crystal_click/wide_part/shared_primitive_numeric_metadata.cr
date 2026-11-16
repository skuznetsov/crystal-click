module CrystalClick
  # One admission-local snapshot for ordinary direct primitive numeric columns.
  # It is discarded after constructing readers; no path-keyed cache survives.
  private class WidePartSharedPrimitiveNumericMetadata
    getter columns : Array({String, String})
    getter codec : String
    getter row_count : UInt64
    getter substreams : Array({String, Array(String)})?

    def initialize(
      @columns : Array({String, String}),
      @codec : String,
      @row_count : UInt64,
      @substreams : Array({String, Array(String)})?,
    )
    end

    def self.try_open(path : String, selected_columns : Array(String)) : WidePartSharedPrimitiveNumericMetadata?
      return nil if selected_columns.empty?

      columns_text = WidePartMetadataFiles.read_metadata_file(path, "columns.txt", require_regular: true)
      columns = WidePart.parse_columns_metadata(columns_text)
      raise UnsupportedFormatError.new("columns.txt contains no columns") if columns.empty?

      seen_selected = Set(String).new
      selected_columns.each do |requested|
        raise BoundsError.new("duplicate selected column") if seen_selected.includes?(requested)
        seen_selected << requested
        exact = columns.find { |entry| entry[0] == requested }
        return nil unless exact && WidePart.supports_numeric_type?(exact[1])
      end

      codec = WidePartMetadataFiles.read_default_codec(path)
      row_count = WidePartMetadataFiles.parse_count_file(path, "count.txt")
      raise CorruptPartError.new("row count exceeds limit") if row_count > WidePart::MAX_ROWS

      substreams_file = File.join(path, "columns_substreams.txt")
      substreams = if File.exists?(substreams_file)
                     text = WidePartMetadataFiles.read_metadata_file(path, "columns_substreams.txt")
                     blocks = WidePart.parse_columns_substreams_metadata(
                       text,
                       columns,
                       enforce_total_substream_limit: false,
                     )
                     seen_streams = Set(String).new
                     blocks.each do |_column, streams|
                       streams.each do |stream|
                         raise UnsupportedFormatError.new("duplicate physical stream name") if seen_streams.includes?(stream)
                         seen_streams << stream
                       end
                     end
                     blocks
                   else
                     nil
                   end

      new(columns, codec, row_count, substreams)
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end
  end
end
