module CrystalClick
  # Per-chunk ordinal dictionary shared by the Object Copy size/index/value
  # owner. Source structures stay borrowed; retained names are copied only
  # after both dictionary and per-entry path work have been budgeted.
  class ObjectSharedCopyDictionary
    getter bucket_count : Int32
    getter row_count : Int32
    getter path_count : Int32

    @structures : Array(ObjectSharedChunkStructure)
    @locations : Array(Tuple(Int32, Int32))
    @paths : Array(String)
    @indexes : Hash(String, Int32)
    @metadata_path_bytes : UInt64
    @materialized : Bool

    def initialize(
      @structures : Array(ObjectSharedChunkStructure),
      budget : BinaryCodecBudget,
    )
      writing = budget.writing?
      @bucket_count = @structures.size
      invalid!(writing, "Object shared Copy requires 1..256 buckets") unless 1 <= @bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i

      first = @structures[0]
      if first.row_count > Int32::MAX.to_u64
        invalid!(writing, "Object shared Copy row count exceeds the in-memory domain")
      end
      @row_count = first.row_count.to_i32

      raw_path_count = 0_u64
      @metadata_path_bytes = 0_u64
      @structures.each_with_index do |structure, bucket_index|
        unless structure.row_count == first.row_count
          invalid!(writing, "Object shared Copy bucket row counts disagree")
        end
        path_count = structure.path_count.to_u64
        if path_count > Int32::MAX.to_u64 - raw_path_count
          invalid!(writing, "Object shared Copy dictionary exceeds the in-memory index domain")
        end
        raw_path_count += path_count
        structure.path_count.times do |path_index|
          path_size = structure.path_byte_size(path_index).to_u64
          if path_size > UInt64::MAX - @metadata_path_bytes
            invalid!(writing, "Object shared Copy dictionary path work overflows UInt64")
          end
          @metadata_path_bytes += path_size
        end
      end

      # Preflight the complete borrowed-name comparison work before comparing
      # bytes or allocating the retained ordinal table. materialize! charges
      # this work exactly once after row-reference work is known.
      budget.ensure_future_elements(@metadata_path_bytes)
      @structures.each_with_index do |structure, bucket_index|
        structure.path_count.times do |path_index|
          if path_index > 0 && compare_source_paths(
               {bucket_index.to_i32, path_index - 1},
               {bucket_index.to_i32, path_index}
             ) >= 0
            invalid!(writing, "Object shared Copy bucket paths are not byte-sorted and unique")
          end
        end
      end
      @path_count = raw_path_count.to_i32

      # Charge bucket/path edges and prove their nodes before retaining the
      # ordinal locator table. Name bytes are charged together with actual row
      # references by materialize!, before any String copies are made.
      edge_count = @bucket_count.to_u64 + raw_path_count
      budget.preflight_children(edge_count)
      budget.charge_node
      edge_count.times { budget.charge_node }
      @locations = Array(Tuple(Int32, Int32)).new(@path_count)
      @structures.each_with_index do |structure, bucket_index|
        structure.path_count.times do |path_index|
          @locations << {bucket_index.to_i32, path_index}
        end
      end
      @paths = [] of String
      @indexes = Hash(String, Int32).new
      @materialized = false
    end

    # Complete the one-time owned-name table after the caller has computed
    # exact repeated row-path work. Both costs are charged before path copies.
    def materialize!(budget : BinaryCodecBudget, referenced_path_bytes : UInt64) : Nil
      return nil if @materialized
      if referenced_path_bytes > UInt64::MAX - @metadata_path_bytes
        invalid!(budget.writing?, "Object shared Copy path work overflows UInt64")
      end
      budget.charge_elements(@metadata_path_bytes + referenced_path_bytes)

      @paths = Array(String).new(@path_count)
      @indexes = Hash(String, Int32).new
      @locations.each_with_index do |location, index|
        bucket_index = location[0]
        path = source_path_string(location)
        unless ObjectSharedBucketLayout.bucket_for(path, @bucket_count) == bucket_index
          invalid!(budget.writing?, "Object shared Copy path is in the wrong bucket")
        end
        if @indexes.has_key?(path)
          invalid!(budget.writing?, "Object shared Copy dictionary paths are not globally unique")
        end
        @paths << path
        @indexes[path] = index.to_i32
      end
      @materialized = true
      nil
    end

    def index_width : Int32
      if @path_count <= 256
        1
      elsif @path_count <= 65_536
        2
      else
        4
      end
    end

    def source_path_byte_size(index : Int) : Int32
      location = @locations[index]
      @structures[location[0]].path_byte_size(location[1])
    end

    def compare_source_paths(left_index : Int, right_index : Int) : Int32
      left = @locations[left_index]
      right = @locations[right_index]
      compare_source_paths(left, right)
    end

    def map_entry(index : Int, value : BinaryValue) : ObjectSharedMapEntry
      raise ArgumentError.new("Object shared Copy dictionary names are not materialized") unless @materialized
      ObjectSharedMapEntry.new(@paths[index].to_slice, value)
    end

    def bucket_at(index : Int) : Int32
      @locations[index][0]
    end

    def find_index(path_size : Int32, &path_byte_at : Int32 -> UInt8) : Int32?
      raise ArgumentError.new("Object shared Copy dictionary names are not materialized") unless @materialized
      key = String.build(path_size) do |io|
        path_size.times { |byte_index| io.write_byte(path_byte_at.call(byte_index)) }
      end
      @indexes[key]?
    end

    private def source_path_string(location : Tuple(Int32, Int32)) : String
      structure = @structures[location[0]]
      path_index = location[1]
      String.build(structure.path_byte_size(path_index)) do |io|
        structure.path_byte_size(path_index).times do |byte_index|
          io.write_byte(structure.path_byte_at(path_index, byte_index))
        end
      end
    end

    private def compare_source_paths(
      left : Tuple(Int32, Int32),
      right : Tuple(Int32, Int32),
    ) : Int32
      left_structure = @structures[left[0]]
      right_structure = @structures[right[0]]
      left_size = left_structure.path_byte_size(left[1])
      right_size = right_structure.path_byte_size(right[1])
      common_size = Math.min(left_size, right_size)
      common_size.times do |byte_index|
        left_byte = left_structure.path_byte_at(left[1], byte_index)
        right_byte = right_structure.path_byte_at(right[1], byte_index)
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left_size <=> right_size
    end

    private def invalid!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
