module CrystalClick
  # :nodoc:
  # Shared bounded parent/child path admission and manifest binding for
  # explicit projection readers. Selected paths are retained privately and
  # exposed only as detached copies; checksum maps remain short lived.
  class ProjectionChildSelection
    @projection_name : String
    @parents : Array({String, String, MergeTreePartInfo})
    @child_paths : Array(String)

    private def initialize(
      @projection_name : String,
      @parents : Array({String, String, MergeTreePartInfo}),
      @child_paths : Array(String),
    )
    end

    def self.prepare(parent_paths : Array(String), projection_name : String) : ProjectionChildSelection
      parents = parent_parts!(parent_paths)
      children = child_paths!(parents, projection_name)
      new(String.new(projection_name.to_slice), parents, children)
    end

    def projection_name : String
      String.new(@projection_name.to_slice)
    end

    def parent_paths : Array(String)
      @parents.map { |parent| String.new(parent[0].to_slice) }
    end

    def selected_parts : Array({String, String, MergeTreePartInfo})
      @parents.map do |path, name, info|
        {String.new(path.to_slice), String.new(name.to_slice), info}
      end
    end

    def child_paths : Array(String)
      @child_paths.map { |path| String.new(path.to_slice) }
    end

    def self.parent_parts!(parent_paths : Array(String)) : Array({String, String, MergeTreePartInfo})
      raise BoundsError.new("no parts selected") if parent_paths.empty?
      raise BoundsError.new("part count exceeds limit") if parent_paths.size > WidePartTable::MAX_PARTS

      selected = Array({String, String, MergeTreePartInfo}).new(parent_paths.size)
      seen_paths = Set(String).new
      parent_paths.each do |requested_path|
        path, name, info = validate_parent_path!(requested_path)
        raise BoundsError.new("duplicate selected part path") unless seen_paths.add?(path)
        selected << {path, name, info}
      end
      selected.each_with_index do |left, left_index|
        (left_index + 1...selected.size).each do |right_index|
          right = selected[right_index]
          if left[2].overlaps?(right[2])
            raise InvalidPartError.new("selected parts overlap: #{left[1]} and #{right[1]}")
          end
        end
      end
      selected
    end

    def self.child_paths!(
      parents : Array({String, String, MergeTreePartInfo}),
      projection_name : String,
    ) : Array(String)
      validate_name!(projection_name)
      paths = Array(String).new(parents.size)
      parents.each do |parent, _name, _info|
        paths << child_path!(parent, projection_name)
      end
      paths
    end

    def self.validate_name!(projection_name : String) : Nil
      if projection_name.bytesize > WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
        raise BoundsError.new("projection child name exceeds limit")
      end
      unless /\A[A-Za-z0-9_]+\z/.matches?(projection_name)
        raise InvalidPartError.new("invalid projection name")
      end
    end

    def self.projection_child_path!(parent_path : String, projection_name : String) : String
      validate_name!(projection_name)
      child_path!(parent_path, projection_name)
    end

    def self.validate_binding!(
      parent_path : String,
      projection_name : String,
      child_checksums : PartChecksums,
    ) : Nil
      parent_entry = PartChecksums.open(parent_path).entry("#{projection_name}.proj")
      raise CorruptPartError.new("parent projection checksum entry is missing") unless parent_entry
      unless !parent_entry.compressed && parent_entry.uncompressed_size.nil?
        raise CorruptPartError.new("projection checksum entry has an invalid shape")
      end

      summary = ProjectionChecksumSummary.new(child_checksums)
      unless parent_entry.physical_size == summary.total_size_on_disk &&
             parent_entry.file_hash == summary.total_checksum
        raise CorruptPartError.new("selected projection child checksum does not match parent manifest")
      end
      nil
    end

    # The complete path set has already been validated by `prepare`. A
    # malformed manifest fails closed here; if Compact is admitted, its reader
    # will preflight every selected parent before invoking callbacks.
    def contains_compact_child? : Bool
      @child_paths.each do |path|
        checksums = PartChecksums.open(path)
        return true if CompactMarkFileAdapter.routing_candidate?(path, checksums)
      end
      false
    end

    private def self.validate_parent_path!(requested_path : String) : {String, String, MergeTreePartInfo}
      if requested_path.empty? || requested_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("part path is empty or exceeds limit")
      end
      path = File.expand_path(requested_path)
      name = File.basename(path)
      raise BoundsError.new("part name exceeds limit") if name.bytesize > WidePartTable::MAX_PART_NAME_BYTES
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, name, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected part")
    end

    private def self.child_path!(parent_path : String, projection_name : String) : String
      path = File.join(parent_path, "#{projection_name}.proj")
      if path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("projection child path exceeds limit")
      end
      name = File.basename(path)
      raise InvalidPartError.new("projection child is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("projection child is not a directory: #{name}") unless Dir.exists?(path)
      path
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected projection child")
    end
  end
end
