module CrystalClick
  # Tagged physical-target declaration. A named UUID constrains a later
  # metadata resolution; an inner UUID is the target identity itself.
  class OfflineMaterializedViewTarget
    @kind : Symbol
    @reference : OfflineTableReference?
    @uuid : String?

    def initialize(kind : Symbol, reference : OfflineTableReference?, uuid : String?)
      case kind
      when :named
        raise UnsupportedFormatError.new("named MATERIALIZED VIEW target requires a table reference") unless reference
        validate_uuid(uuid.not_nil!, true) if uuid
      when :inner_uuid
        raise UnsupportedFormatError.new("INNER UUID MATERIALIZED VIEW target requires a UUID") unless uuid
        validate_uuid(uuid.not_nil!, false)
        raise UnsupportedFormatError.new("INNER UUID MATERIALIZED VIEW target cannot contain a named reference") if reference
      when :implicit_inner
        raise UnsupportedFormatError.new("implicit inner MATERIALIZED VIEW target cannot contain a reference or UUID") if reference || uuid
      else
        raise UnsupportedFormatError.new("unknown MATERIALIZED VIEW target kind")
      end

      @kind = kind
      @reference = reference.try(&.copy)
      @uuid = uuid.try { |value| detached_string(value.downcase) }
    end

    def self.named(reference : OfflineTableReference, uuid : String? = nil) : OfflineMaterializedViewTarget
      new(:named, reference, uuid)
    end

    def self.inner_uuid(uuid : String) : OfflineMaterializedViewTarget
      new(:inner_uuid, nil, uuid)
    end

    def self.implicit_inner : OfflineMaterializedViewTarget
      new(:implicit_inner, nil, nil)
    end

    private def validate_uuid(uuid : String, allow_nil : Bool) : Nil
      unless /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.matches?(uuid)
        raise UnsupportedFormatError.new("invalid UUID in MATERIALIZED VIEW target")
      end
      if !allow_nil && uuid.compare("00000000-0000-0000-0000-000000000000", case_insensitive: true) == 0
        raise UnsupportedFormatError.new("INNER UUID MATERIALIZED VIEW target cannot use a Nil UUID")
      end
    end

    def kind : Symbol
      @kind
    end

    def reference : OfflineTableReference?
      @reference.try(&.copy)
    end

    def uuid : String?
      @uuid.try { |value| detached_string(value) }
    end

    def copy : OfflineMaterializedViewTarget
      OfflineMaterializedViewTarget.new(@kind, @reference, @uuid)
    end

    private def detached_string(value : String) : String
      String.new(value.to_slice)
    end
  end
end
