module CrystalClick
  # Detached first-block authority for each Dynamic-bearing opaque Bulk site
  # inside one recursive Compact JSON column. The outer map is keyed by the
  # canonical schema path; each existing CompactDynamicWriteContext keeps its
  # own Dynamic structure paths rooted at "root".
  class CompactRecursiveDynamicWriteContext
    @site_contexts : Hash(String, CompactDynamicWriteContext)

    def initialize(site_contexts : Hash(String, CompactDynamicWriteContext))
      unless site_contexts.empty?
        raise ArgumentError.new("recursive Compact Dynamic contexts require their declared schema")
      end
      @site_contexts = {} of String => CompactDynamicWriteContext
    end

    # Validate the caller-owned map against the schema before allocating the
    # detached map or copying any path keys. Exact path validation walks the
    # schema from each supplied canonical path; the expected roster is never
    # materialized as a second proportional collection.
    def initialize(schema : StorageColumnSchema, site_contexts : Hash(String, CompactDynamicWriteContext))
      self.class.validate_site_contexts!(schema, site_contexts)
      @site_contexts = detached_site_contexts(site_contexts)
    end

    private def detached_site_contexts(
      site_contexts : Hash(String, CompactDynamicWriteContext),
    ) : Hash(String, CompactDynamicWriteContext)
      detached = Hash(String, CompactDynamicWriteContext).new(initial_capacity: site_contexts.size)
      site_contexts.each do |path, context|
        if path.empty?
          raise ArgumentError.new("recursive Compact Dynamic context site paths must be nonempty")
        end
        detached_path = String.new(path.to_slice)
        if detached.has_key?(detached_path)
          raise ArgumentError.new("recursive Compact Dynamic context site paths must be unique")
        end
        detached[detached_path] = context
      end
      detached
    end

    def site_contexts : Hash(String, CompactDynamicWriteContext)
      detached = Hash(String, CompactDynamicWriteContext).new(initial_capacity: @site_contexts.size)
      @site_contexts.each do |path, context|
        detached[String.new(path.to_slice)] = context
      end
      detached
    end

    def site_count : Int32
      @site_contexts.size
    end

    def has_site?(path : String) : Bool
      @site_contexts.has_key?(path)
    end

    def site_context_for(path : String) : CompactDynamicWriteContext
      @site_contexts[path]? ||
        raise(UnsupportedFormatError.new("recursive Compact Dynamic context is missing a declared Bulk site"))
    end

    # Read-only traversal avoids allocating a second detached map during
    # callback-plan validation. Immutable contexts may be intentionally reused
    # at multiple compatible schema paths.
    def each_site_context(&block : String, CompactDynamicWriteContext -> Nil) : Nil
      @site_contexts.each { |path, context| yield path, context }
      nil
    end

    # Verify exact schema ownership without constructing a proportional roster.
    # The schema is already bounded by StorageColumnSchema's parser and the
    # caller performs normal codec-budget preflight before callback planning.
    def validate_schema!(schema : StorageColumnSchema) : Nil
      self.class.validate_site_contexts!(schema, @site_contexts)
      nil
    end

    def self.validate_site_contexts!(
      schema : StorageColumnSchema,
      site_contexts : Hash(String, CompactDynamicWriteContext),
    ) : Nil
      expected_count = count_dynamic_sites(schema)
      unless expected_count == site_contexts.size
        raise UnsupportedFormatError.new("recursive Compact Dynamic contexts differ from the declared Dynamic Bulk sites")
      end
      site_contexts.each do |path, _context|
        unless dynamic_site_path?(schema, path)
          raise UnsupportedFormatError.new("recursive Compact Dynamic context contains an undeclared Bulk site")
        end
      end
      nil
    end

    private def self.count_dynamic_sites(schema : StorageColumnSchema) : Int32
      if schema.bulk?
        type = schema.bulk_type
        type.tag == BinaryDataType::TAG_DYNAMIC && !type.contains_json? ? 1 : 0
      elsif schema.array?
        count_dynamic_sites(schema.child_at(0))
      elsif schema.tuple?
        count = 0
        schema.child_count.times do |index|
          count += count_dynamic_sites(schema.child_at(index))
        end
        count
      else
        0
      end
    end

    # Parse only the canonical recursive schema path. This intentionally does
    # not call StorageColumnSchema's path enumerators, which would build a full
    # proportional path roster before caller-map bounds were checked.
    private def self.dynamic_site_path?(schema : StorageColumnSchema, path : String) : Bool
      return false unless matches_ascii_at?(path, 0, "root")
      position = 4
      current = schema
      while position < path.bytesize
        return false unless path.byte_at(position) == '/'.ord.to_u8
        position += 1
        if matches_ascii_at?(path, position, "array[0]")
          return false unless current.array?
          position += 8
          current = current.child_at(0)
        elsif matches_ascii_at?(path, position, "tuple[")
          return false unless current.tuple?
          position += 6
          start = position
          tuple_index = 0
          while position < path.bytesize
            byte = path.byte_at(position)
            break if byte == ']'.ord.to_u8
            return false if byte < '0'.ord.to_u8 || byte > '9'.ord.to_u8
            digit = (byte - '0'.ord.to_u8).to_i
            return false if tuple_index > (Int32::MAX - digit) // 10
            tuple_index = tuple_index * 10 + digit
            position += 1
          end
          return false if position == start || position >= path.bytesize
          return false if path.byte_at(start) == '0'.ord.to_u8 && position - start > 1
          return false unless path.byte_at(position) == ']'.ord.to_u8
          return false if tuple_index >= current.child_count
          position += 1
          current = current.child_at(tuple_index)
        else
          return false
        end
      end
      if current.bulk?
        type = current.bulk_type
        type.tag == BinaryDataType::TAG_DYNAMIC && !type.contains_json?
      else
        false
      end
    rescue ex : ArgumentError | IndexError | UnsupportedFormatError
      false
    end

    private def self.matches_ascii_at?(value : String, offset : Int32, literal : String) : Bool
      return false if offset < 0 || literal.bytesize > value.bytesize - offset
      literal.bytesize.times do |index|
        return false unless value.byte_at(offset + index) == literal.byte_at(index)
      end
      true
    end

    def same_context?(other : CompactRecursiveDynamicWriteContext) : Bool
      return false unless @site_contexts.size == other.@site_contexts.size
      @site_contexts.each do |path, context|
        candidate = other.@site_contexts[path]?
        return false unless candidate && same_dynamic_context?(context, candidate)
      end
      true
    end

    # Logical owner census for the detached path map and bound context owners.
    # It is not a full retained-byte/RSS bound: immutable structure owners and
    # allocator capacities are not included, and reused contexts are counted
    # once per binding.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveDynamicWriteContext).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, CompactDynamicWriteContext)).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@site_contexts.size.to_u64, sizeof({String, CompactDynamicWriteContext}).to_u64),
      )
      @site_contexts.each do |path, context|
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, path.bytesize.to_u64 + 1_u64)
        bytes = checked_add(bytes, context.retained_workspace_bytes)
      end
      bytes
    end

    private def same_dynamic_context?(left : CompactDynamicWriteContext, right : CompactDynamicWriteContext) : Bool
      return false unless left.site_count == right.site_count
      left.each_site_structure do |path, structure|
        candidate = right.structure_at?(path)
        return false unless candidate && candidate == structure
      end
      true
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Dynamic context workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("recursive Compact Dynamic context workspace overflows UInt64")
      end
      left * right
    end
  end
end
