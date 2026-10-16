# Narrow W283 location policy for the user-approved external SSD.

module CompactVariantBulkW283Paths
  SSD_ALIAS = '/opt/mldata_ssd'.freeze
  TASK_ROOT_PATTERN = /\Acrystal-click-w283\.[A-Za-z0-9]{6}\z/.freeze

  class Error < StandardError; end

  class Policy
    def initialize(alias_root: SSD_ALIAS, internal_root: '/')
      @alias_root = File.expand_path(alias_root)
      @internal_root = File.expand_path(internal_root)
    end

    def validate_evidence_root(path, purpose:)
      raise Error, 'evidence-root purpose must be probe or audit' unless %i[probe audit].include?(purpose)
      location = resolve_task_path(path)
      unless File.dirname(location.fetch(:path)) == location.fetch(:task_root)
        raise Error, 'evidence root must be a direct child of the owned W283 task root'
      end
      if purpose == :probe && !Dir.children(location.fetch(:path)).empty?
        raise Error, 'probe evidence root must already exist and be empty'
      end
      location.fetch(:path)
    end

    def validate_source_root(path)
      validate_task_path(path, kind: :directory)
    end

    def validate_task_file(path)
      validate_task_path(path, kind: :file)
    end

    private

    def validate_task_path(path, kind:)
      location = resolve_task_path(path)
      task_root = location.fetch(:task_root)
      descendants = location.fetch(:path).delete_prefix("#{task_root}#{File::SEPARATOR}")
      if descendants == location.fetch(:path) || descendants.empty?
        raise Error, 'W283 source/runtime/helper path must be below its owned task root'
      end
      stat = File.stat(location.fetch(:path))
      valid_kind = kind == :directory ? stat.directory? : stat.file?
      raise Error, "W283 task path must be an existing #{kind}" unless valid_kind
      location.fetch(:path)
    end

    def resolve_task_path(path)
      raise Error, 'W283 task path is required' unless path.is_a?(String) && !path.empty?

      mount_root, mount_device = mounted_root!
      expanded = File.expand_path(path)
      relative = relative_below(expanded, @alias_root) || relative_below(expanded, mount_root)
      raise Error, 'W283 path must use /opt/mldata_ssd or its canonical mount path' unless relative

      components = relative.split(File::SEPARATOR).reject(&:empty?)
      unless components.size >= 3 && components[0] == 'cache' && TASK_ROOT_PATTERN.match?(components[1])
        raise Error, 'W283 path must be within cache/crystal-click-w283.<mktemp suffix>'
      end

      task_root = File.join(mount_root, *components.first(2))
      task_stat = nil
      components.each_with_index do |_component, index|
        current = File.join(mount_root, *components.first(index + 1))
        stat = File.lstat(current)
        raise Error, 'W283 task path contains a descendant symlink' if stat.symlink?
        raise Error, 'W283 task path leaves the approved SSD device' unless stat.dev == mount_device
        task_stat = stat if index == 1
      rescue Errno::ENOENT
        raise Error, 'W283 task path component is missing'
      end

      unless task_stat&.directory? && task_stat.uid == Process.uid
        raise Error, 'W283 task root must be an existing directory owned by the current user'
      end

      canonical_path = File.join(mount_root, *components)
      raise Error, 'W283 task path is not canonical beneath its SSD root' unless File.realpath(expanded) == canonical_path

      {path: canonical_path, task_root: task_root}
    rescue Errno::ENOENT
      raise Error, 'W283 task path component is missing'
    end

    def mounted_root!
      unless File.directory?(@alias_root)
        raise Error, 'approved external SSD mount is unavailable'
      end

      mount_root = File.realpath(@alias_root)
      mount_device = File.stat(mount_root).dev
      internal_device = File.stat(@internal_root).dev
      raise Error, 'approved SSD resolves to the internal/root device' if mount_device == internal_device
      [mount_root, mount_device]
    rescue Errno::ENOENT
      raise Error, 'approved external SSD mount is unavailable'
    end

    def relative_below(path, root)
      return nil unless path.start_with?("#{root}#{File::SEPARATOR}")
      path.delete_prefix("#{root}#{File::SEPARATOR}")
    end
  end

  DEFAULT_POLICY = Policy.new.freeze

  def self.validate_evidence_root(path, purpose:)
    DEFAULT_POLICY.validate_evidence_root(path, purpose: purpose)
  end

  def self.validate_source_root(path)
    DEFAULT_POLICY.validate_source_root(path)
  end

  def self.validate_task_file(path)
    DEFAULT_POLICY.validate_task_file(path)
  end
end
