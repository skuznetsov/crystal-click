module CrystalClick
  # Detached complete physical lanes for paired logical Object document
  # composition. Malformed lane sets and grids are retained for the decoder to
  # classify; construction does not certify a stream profile.
  class ObjectDocumentStreams
    @structures : ObjectDynamicStructureStreams
    @rows_per_mark : Array(UInt64)
    @typed_paths : Hash(String, BinaryBulkStreams)
    @typed_names : Array(String)
    @typed_dynamic_paths : Hash(String, BinaryDynamicBulkStreams)
    @typed_dynamic_names : Array(String)
    @typed_dynamic_statistics_offsets : Hash(String, Int32)
    @typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32))
    @typed_dynamic_mode : UInt64
    @dynamic_paths : Hash(String, DynamicValueStreams)
    @dynamic_names : Array(String)
    @shared_buckets : Array(BinaryBulkStreams)
    @advanced_shared_rows : Array(Array(ObjectSharedMapRow))

    def initialize(
      structures : ObjectDynamicStructureStreams,
      rows_per_mark : Array(UInt64),
      typed_paths : Hash(String, BinaryBulkStreams),
      dynamic_paths : Hash(String, DynamicValueStreams),
      shared : BinaryBulkStreams | Array(BinaryBulkStreams),
      typed_dynamic_paths : Hash(String, BinaryDynamicBulkStreams) = Hash(String, BinaryDynamicBulkStreams).new,
      typed_dynamic_statistics_offsets : Hash(String, Int32) = Hash(String, Int32).new,
      typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32)) = Hash(String, Hash(String, Int32)).new,
      typed_dynamic_mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
      advanced_shared_rows : Array(Array(ObjectSharedMapRow)) = [] of Array(ObjectSharedMapRow),
    )
      @structures = structures
      @rows_per_mark = rows_per_mark.dup
      @typed_dynamic_mode = typed_dynamic_mode
      @typed_paths = Hash(String, BinaryBulkStreams).new
      @typed_names = Array(String).new(typed_paths.size)
      typed_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @typed_paths.has_key?(detached_path)
          raise ArgumentError.new("typed Object lane keys must be unique by raw bytes")
        end
        @typed_paths[detached_path] = streams
        @typed_names << detached_path
      end
      @typed_names.sort! { |left, right| compare_paths(left, right) }

      @typed_dynamic_paths = Hash(String, BinaryDynamicBulkStreams).new
      @typed_dynamic_names = Array(String).new(typed_dynamic_paths.size)
      typed_dynamic_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @typed_dynamic_paths.has_key?(detached_path)
          raise ArgumentError.new("typed Dynamic Object lane keys must be unique by raw bytes")
        end
        @typed_dynamic_paths[detached_path] = streams
        @typed_dynamic_names << detached_path
      end
      @typed_dynamic_names.sort! { |left, right| compare_paths(left, right) }
      @typed_dynamic_statistics_offsets = Hash(String, Int32).new
      @typed_dynamic_site_statistics_offsets = Hash(String, Hash(String, Int32)).new
      typed_dynamic_statistics_offsets.each do |path, offset|
        detached_path = String.new(path.to_slice)
        streams = @typed_dynamic_paths[detached_path]? || raise(ArgumentError.new("typed Dynamic statistics offset has no matching lane: #{path.inspect}"))
        unless streams.structures.has_site?("root")
          raise ArgumentError.new("typed Dynamic root statistics offset has no matching root site: #{path.inspect}")
        end
        validate_statistics_offset!(offset)
        @typed_dynamic_statistics_offsets[detached_path] = offset
        site_offsets = Hash(String, Int32).new
        site_offsets["root"] = offset
        @typed_dynamic_site_statistics_offsets[detached_path] = site_offsets
      end
      typed_dynamic_site_statistics_offsets.each do |path, offsets|
        detached_path = String.new(path.to_slice)
        streams = @typed_dynamic_paths[detached_path]? || raise(ArgumentError.new("typed Dynamic site statistics offsets have no matching lane: #{path.inspect}"))
        site_offsets = @typed_dynamic_site_statistics_offsets[detached_path]?
        unless site_offsets
          site_offsets = Hash(String, Int32).new
          @typed_dynamic_site_statistics_offsets[detached_path] = site_offsets
        end
        offsets.each do |site_path, offset|
          unless streams.structures.has_site?(site_path)
            raise ArgumentError.new("typed Dynamic statistics offset has no matching site: #{path.inspect}:#{site_path.inspect}")
          end
          validate_statistics_offset!(offset)
          detached_site_path = String.new(site_path.to_slice)
          if previous = site_offsets[detached_site_path]?
            unless previous == offset
              raise ArgumentError.new("typed Dynamic root statistics offsets conflict for #{path.inspect}")
            end
          else
            site_offsets[detached_site_path] = offset
          end
        end
      end

      @dynamic_paths = Hash(String, DynamicValueStreams).new
      @dynamic_names = Array(String).new(dynamic_paths.size)
      dynamic_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @dynamic_paths.has_key?(detached_path)
          raise ArgumentError.new("Dynamic Object lane keys must be unique by raw bytes")
        end
        @dynamic_paths[detached_path] = streams
        @dynamic_names << detached_path
      end
      @dynamic_names.sort! { |left, right| compare_paths(left, right) }
      @shared_buckets = if shared.is_a?(BinaryBulkStreams)
                          [shared] of BinaryBulkStreams
                        else
                          shared.dup
                        end
      unless advanced_shared_rows.empty?
        unless advanced_shared_rows.size == @rows_per_mark.size
          raise ArgumentError.new("advanced shared Object rows must match the outer mark grid")
        end
        advanced_shared_rows.each_with_index do |rows, mark_index|
          unless rows.size.to_u64 == @rows_per_mark[mark_index]
            raise ArgumentError.new("advanced shared Object rows must match each mark's logical row count")
          end
        end
      end
      @advanced_shared_rows = Array(Array(ObjectSharedMapRow)).new(advanced_shared_rows.size)
      advanced_shared_rows.each { |rows| @advanced_shared_rows << rows.dup }
    end

    def structures : ObjectDynamicStructureStreams
      @structures
    end

    def mark_count : Int32
      @rows_per_mark.size
    end

    def row_count_at(mark_index : Int) : UInt64
      @rows_per_mark[mark_index]
    end

    def rows_per_mark : Array(UInt64)
      @rows_per_mark.dup
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_names[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_names[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_names[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_paths.has_key?(path)
    end

    def typed_paths : Array(String)
      @typed_names.map { |path| String.new(path.to_slice) }
    end

    def typed_for(path : String) : BinaryBulkStreams
      @typed_paths[path]? || raise(KeyError.new("typed Object lanes not found: #{path.inspect}"))
    end

    def typed_dynamic_path_count : Int32
      @typed_dynamic_paths.size
    end

    def typed_dynamic_path_at(index : Int) : String
      String.new(@typed_dynamic_names[index].to_slice)
    end

    def has_typed_dynamic_path?(path : String) : Bool
      @typed_dynamic_paths.has_key?(path)
    end

    def typed_dynamic_paths : Array(String)
      @typed_dynamic_names.map { |path| String.new(path.to_slice) }
    end

    def typed_dynamic_for(path : String) : BinaryDynamicBulkStreams
      @typed_dynamic_paths[path]? || raise(KeyError.new("typed Object Dynamic lanes not found: #{path.inspect}"))
    end

    # Physical discriminator mode owned by the declared typed-Dynamic value
    # lanes. Their BinaryBulk streams remain normalized RowBinary tag streams.
    def typed_dynamic_mode : UInt64
      @typed_dynamic_mode
    end

    # Relative byte offset of the root Dynamic statistics flag within the
    # exact structure blob produced or parsed for this typed child.
    def typed_dynamic_statistics_offset(path : String) : Int32?
      if offset = @typed_dynamic_statistics_offsets[path]?
        return offset
      end
      streams = @typed_dynamic_paths[path]?
      return nil unless streams && streams.structures.site_count == 1 && streams.structures.has_site?("root")
      site_offsets = @typed_dynamic_site_statistics_offsets[path]?
      return nil unless site_offsets
      site_offsets["root"]?
    end

    # Relative byte offset of a site's statistics flag. Missing offsets are
    # tolerated for decoded/caller-constructed streams; the writer lane binder
    # requires a complete per-site map before emitting physical lanes.
    def typed_dynamic_site_statistics_offset(path : String, site_path : String) : Int32?
      site_offsets = @typed_dynamic_site_statistics_offsets[path]?
      return nil unless site_offsets
      site_offsets[site_path]?
    end

    def dynamic_path_count : Int32
      @dynamic_paths.size
    end

    def dynamic_path_at(index : Int) : String
      String.new(@dynamic_names[index].to_slice)
    end

    def dynamic_path_byte_size_at(index : Int) : Int32
      @dynamic_names[index].bytesize
    end

    def dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @dynamic_names[index].to_slice[byte_index]
    end

    def has_dynamic_path?(path : String) : Bool
      @dynamic_paths.has_key?(path)
    end

    def dynamic_paths : Array(String)
      @dynamic_names.map { |path| String.new(path.to_slice) }
    end

    def dynamic_for(path : String) : DynamicValueStreams
      @dynamic_paths[path]? || raise(KeyError.new("Dynamic Object lanes not found: #{path.inspect}"))
    end

    def shared : BinaryBulkStreams
      unless @shared_buckets.size == 1
        raise ArgumentError.new("Object shared lane is ambiguous for a multi-bucket layout")
      end
      @shared_buckets[0]
    end

    def shared_bucket_count : Int32
      @shared_buckets.size
    end

    def shared_bucket(index : Int) : BinaryBulkStreams
      @shared_buckets[index]? || raise(IndexError.new("Object shared bucket index is outside the lane roster"))
    end

    def advanced_shared_mark_count : Int32
      @advanced_shared_rows.size
    end

    def advanced_shared_row_count_at(mark_index : Int) : Int32
      @advanced_shared_rows[mark_index].size
    end

    def advanced_shared_row_at(mark_index : Int, row_index : Int) : ObjectSharedMapRow
      @advanced_shared_rows[mark_index][row_index]
    end

    # Detached outer/mark arrays; ObjectSharedMapRow values are immutable and
    # remain shared snapshots. The complete row-reference matrix is budgeted
    # before any proportional array copy.
    def advanced_shared_rows(budget : BinaryCodecBudget) : Array(Array(ObjectSharedMapRow))
      mark_count = @advanced_shared_rows.size.to_u64
      row_count = 0_u64
      @advanced_shared_rows.each do |rows|
        if rows.size.to_u64 > UInt64::MAX - row_count
          raise UnsupportedFormatError.new("advanced shared Object row count overflows UInt64")
        end
        row_count += rows.size.to_u64
      end
      if row_count > UInt64::MAX - mark_count
        raise UnsupportedFormatError.new("advanced shared Object row matrix overflows UInt64")
      end
      nodes = mark_count + row_count
      budget.ensure_future_nodes(nodes)
      budget.ensure_future_elements(nodes)
      nodes.times { budget.charge_node }
      budget.charge_elements(nodes)
      output = Array(Array(ObjectSharedMapRow)).new(@advanced_shared_rows.size)
      @advanced_shared_rows.each { |rows| output << rows.dup }
      output
    end

    private def compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def validate_statistics_offset!(offset : Int32) : Nil
      if offset < 0
        raise ArgumentError.new("typed Dynamic statistics offset must be non-negative")
      end
    end
  end
end
