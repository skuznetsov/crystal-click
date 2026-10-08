module CrystalClick
  # Detached, immutable declaration metadata for one persisted classic MV.
  # Source references are a bounded syntactic inventory, not runtime triggers.
  class OfflineMaterializedView
    @declaring_database : String
    @query : String
    @inner_engine : String?
    @target : OfflineMaterializedViewTarget
    @source_references : Array(OfflineTableReference)
    @source_references_status : Symbol
    @source_references_reason : String?

    def initialize(
      declaring_database : String,
      query : String,
      inner_engine : String?,
      target : OfflineMaterializedViewTarget,
      source_references : Array(OfflineTableReference),
      source_references_status : Symbol,
      source_references_reason : String?,
    )
      raise UnsupportedFormatError.new("MATERIALIZED VIEW declaring database is empty") if declaring_database.empty?
      raise UnsupportedFormatError.new("MATERIALIZED VIEW SELECT query is empty") if query.empty?

      case source_references_status
      when :complete
        raise UnsupportedFormatError.new("complete MATERIALIZED VIEW source inventory cannot have an unknown reason") if source_references_reason
      when :unknown
        raise UnsupportedFormatError.new("unknown MATERIALIZED VIEW source inventory must not expose partial references") unless source_references.empty?
        reason = source_references_reason
        raise UnsupportedFormatError.new("unknown MATERIALIZED VIEW source inventory requires a reason") unless reason && !reason.empty?
      else
        raise UnsupportedFormatError.new("unknown MATERIALIZED VIEW source-inventory status")
      end

      @declaring_database = detached_string(declaring_database)
      @query = detached_string(query)
      @inner_engine = inner_engine.try { |value| detached_string(value) }
      @target = target.copy
      @source_references = source_references.map(&.copy)
      @source_references_status = source_references_status
      @source_references_reason = source_references_reason.try { |value| detached_string(value) }
    end

    def declaring_database : String
      detached_string(@declaring_database)
    end

    def query : String
      detached_string(@query)
    end

    def inner_engine : String?
      @inner_engine.try { |value| detached_string(value) }
    end

    def target : OfflineMaterializedViewTarget
      @target.copy
    end

    def source_references : Array(OfflineTableReference)
      @source_references.map(&.copy)
    end

    def source_references_status : Symbol
      @source_references_status
    end

    def source_references_complete? : Bool
      @source_references_status == :complete
    end

    def source_references_reason : String?
      @source_references_reason.try { |value| detached_string(value) }
    end

    def copy : OfflineMaterializedView
      OfflineMaterializedView.new(
        declaring_database: @declaring_database,
        query: @query,
        inner_engine: @inner_engine,
        target: @target,
        source_references: @source_references,
        source_references_status: @source_references_status,
        source_references_reason: @source_references_reason
      )
    end

    private def detached_string(value : String) : String
      String.new(value.to_slice)
    end
  end
end
