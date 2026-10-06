module CrystalClick
  # Reopens one normalized Array(JSON) Object column from a plain Wide part.
  # Parent row counts and child occurrences remain separate coordinates; the
  # Object reader owns all inner value and Dynamic decoding.
  class ArrayObjectColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @inner_schema : ObjectDocumentSchema
    @typed_schema : Hash(String, BinaryDataType)
    @limits : BinaryCodecLimits
    @child_limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @descriptor : ObjectDocumentFileDescriptor
    @schema_declaration : String
    @source_declaration : String

    # The expected schema describes the JSON element, not the outer Array.
    def self.open(
      part_path : String,
      column_name : String,
      expected_schema : ObjectDocumentSchema,
    ) : ArrayObjectColumnReader
      new(part_path, column_name, expected_schema)
    end

    # Recognizes the exact canonical Array(JSON(...)) subset admitted by this
    # reader. It is deliberately not a general ClickHouse type parser.
    def self.schema_for_source_declaration(
      source_declaration : String,
      limits : BinaryCodecLimits = ObjectDocumentSchema::DEFAULT_LIMITS,
    ) : ObjectDocumentSchema?
      prefix = "Array("
      return nil unless source_declaration.starts_with?(prefix) && source_declaration.ends_with?(")")
      return nil if source_declaration.bytesize <= prefix.bytesize + 1

      inner_bytes = source_declaration.to_slice[prefix.bytesize, source_declaration.bytesize - prefix.bytesize - 1]
      inner = String.new(inner_bytes)
      schema = ObjectDocumentSchema.parse_declaration(inner, limits)
      return nil unless "Array(#{schema.declaration})" == source_declaration
      schema
    rescue ex : UnsupportedFormatError
      nil
    end

    private def initialize(
      part_path : String,
      column_name : String,
      expected_schema : ObjectDocumentSchema,
    )
      metadata = ObjectColumnPartMetadata.open(part_path, column_name)
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      @inner_schema = expected_schema
      @limits = expected_schema.limits
      @child_limits = child_limits_for(@limits)
      @transport_limits = CompressedStreamLimits.new
      @schema_declaration = "Array(#{expected_schema.declaration})"
      @source_declaration = metadata.source_declaration
      @ordinary_profile = metadata.ordinary_profile

      source_schema = self.class.schema_for_source_declaration(@source_declaration, @limits) ||
                      raise(UnsupportedFormatError.new("selected column is not an admitted Array(JSON) declaration"))
      unless source_schema.declaration == expected_schema.declaration
        raise CorruptPartError.new("part Array(JSON) declaration differs from the expected schema")
      end

      # The Array wrapper consumes exactly one logical depth. Rebuilding the
      # schema under the reduced limit ensures plan validation cannot reset it.
      bounded_schema = ObjectDocumentSchema.new(
        expected_schema.typed_paths,
        max_dynamic_paths: expected_schema.max_dynamic_paths,
        max_dynamic_types: expected_schema.max_dynamic_types,
        limits: @child_limits,
      )
      unless bounded_schema.declaration == expected_schema.declaration
        raise UnsupportedFormatError.new("Array(JSON) child schema changed under the wrapper depth limit")
      end
      @typed_schema = bounded_schema.typed_paths

      @descriptor = ObjectDocumentFileReader.inspect_child_site(
        @part_path,
        @column_name,
        @typed_schema,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        @child_limits,
        @transport_limits,
      )
      begin
        bounded_schema.validate_plan(@descriptor.plan)
        source_schema.validate_plan(@descriptor.plan)
      rescue ex : ArgumentError
        raise CorruptPartError.new(ex.message || "Array(JSON) schema does not match its physical plan")
      end

      unless @descriptor.row_count == metadata.row_count
        raise CorruptPartError.new("count.txt disagrees with the Array(JSON) outer mark grid")
      end

      selected_stream_names = metadata.selected_stream_names
      expected_stream_names = @descriptor.physical_stream_names
      selected_stream_names.sort!
      expected_stream_names.sort!
      unless selected_stream_names == expected_stream_names
        raise CorruptPartError.new("selected columns_substreams roster differs from the Array(JSON) physical plan")
      end

      @row_count = metadata.row_count
      @mark_count = @descriptor.mark_count
      @logical_read_bytes = @descriptor.logical_read_bytes
    end

    def mark_row_counts : Array(UInt64)
      @descriptor.mark_row_counts
    end

    # Logical substream names, including the outer .size0 lane.
    def physical_stream_names : Array(String)
      @descriptor.physical_stream_names
    end

    # Checksummed hashed filenames selected from columns_substreams.txt.
    def selected_checksum_names : Array(String)
      @descriptor.selected_checksum_names
    end

    # Canonical type declaration exposed by this column reader.
    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    # Exact literal type text stored in columns.txt.
    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    # Full checked .size0 schedule; each result is the child occurrence count
    # for one physical parent mark, not the physical parent-row count.
    def child_occurrence_row_counts(first_mark : Int, mark_count : Int) : Array(UInt64)
      @descriptor.child_occurrence_row_counts(first_mark, mark_count)
    end

    # Returns marks -> parent rows -> Object documents. A zero child count is
    # represented by an empty row array and does not manufacture an Object row.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(Array(ObjectDocument)))
      if first_mark < 0 || mark_count < 0 || first_mark > @mark_count || mark_count > @mark_count - first_mark
        raise ArgumentError.new("mark selection is outside the Array(JSON) grid")
      end

      selected = ObjectDocumentFileReader.read_child_site(
        @part_path,
        @column_name,
        @typed_schema,
        first_mark,
        mark_count,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        @child_limits,
        @transport_limits,
      )
      unless selected.size == mark_count
        raise CorruptPartError.new("bounded Array(JSON) read returned the wrong number of marks")
      end

      expected_parents = @descriptor.mark_row_counts
      expected_children = @descriptor.child_occurrence_row_counts(first_mark, mark_count)
      mark_count.times do |index|
        parents = selected[index]
        unless parents.size.to_u64 == expected_parents[first_mark + index]
          raise CorruptPartError.new("bounded Array(JSON) read returned the wrong parent row count")
        end
        observed_children = 0_u64
        parents.each do |documents|
          observed_children = checked_add(observed_children, documents.size.to_u64)
        end
        unless observed_children == expected_children[index]
          raise CorruptPartError.new("bounded Array(JSON) read returned a child count that differs from .size0")
        end
      end
      selected
    end

    private def child_limits_for(limits : BinaryCodecLimits) : BinaryCodecLimits
      if limits.max_depth < 1
        raise UnsupportedFormatError.new("Array(JSON) wrapper exceeds the configured codec depth limit")
      end
      BinaryCodecLimits.new(
        limits.max_depth - 1,
        limits.max_nodes,
        limits.max_elements,
        limits.max_bytes,
      )
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Array(JSON) selected child count overflows UInt64")
      end
      left + right
    end
  end
end
