module CrystalClick
  # Detached metadata for one normalized Object document column. The plan
  # owns the admitted Object/Dynamic structure; all array and string views
  # crossing this boundary are copied on construction and access.
  class ObjectDocumentFileDescriptor
    getter plan : ObjectDocumentPlan
    getter row_count : UInt64
    getter logical_read_bytes : UInt64

    @mark_row_counts : Array(UInt64)
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)

    def initialize(
      @plan : ObjectDocumentPlan,
      mark_row_counts : Array(UInt64),
      physical_stream_names : Array(String),
      selected_checksum_names : Array(String),
      @logical_read_bytes : UInt64,
    )
      @mark_row_counts = mark_row_counts.dup
      @row_count = 0_u64
      @mark_row_counts.each do |rows|
        if @row_count > UInt64::MAX - rows
          raise CorruptPartError.new("Object descriptor row count overflows UInt64")
        end
        @row_count += rows
      end

      @physical_stream_names = copy_names(physical_stream_names)
      @selected_checksum_names = copy_names(selected_checksum_names)
    end

    def mark_row_counts : Array(UInt64)
      @mark_row_counts.dup
    end

    # Logical names recorded in columns_substreams.txt. They are not physical
    # filenames; hashed aliases live in selected_checksum_names.
    def physical_stream_names : Array(String)
      copy_names(@physical_stream_names)
    end

    def selected_checksum_names : Array(String)
      copy_names(@selected_checksum_names)
    end

    private def copy_names(names : Array(String)) : Array(String)
      detached = Array(String).new(names.size)
      names.each { |name| detached << String.new(name.to_slice) }
      detached
    end
  end
end
