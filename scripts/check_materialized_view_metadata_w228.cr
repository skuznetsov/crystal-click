require "digest/sha256"
require "json"
require "../src/crystal_click"

module CheckMaterializedViewMetadataW228
  extend self

  FORMAT_INPUT    = "materialized_view_metadata_w228_input_v1"
  FORMAT_OUTPUT   = "materialized_view_metadata_w228_helper_v1"
  NATIVE_PREFIX   = "/private/tmp/crystal-click-w228-native."
  EVIDENCE_PREFIX = "/private/tmp/crystal-click-w228-evidence."
  VIEW_IDS        = [
    "named_unqualified",
    "cross_database_target",
    "cross_database_source",
    "source_free_named_target",
    "cte_unknown",
    "inner_uuid_explicit",
    "engine_canonical_inner_uuid",
    "join_unknown",
    "subquery_unknown",
    "literal_fake_from_to",
    "quoted_identifiers",
  ]
  CONTROL_IDS  = ["refresh_control", "security_control"]
  NEGATIVE_IDS = ["ordinary_table", "missing_view"]

  private def fail!(message : String) : NoReturn
    raise "W228 helper: #{message}"
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def nullable_string(value : String?) : JSON::Any
    value ? JSON::Any.new(value) : JSON::Any.new(nil)
  end

  private def string_array(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def safe_input(path : String) : JSON::Any
    full = File.expand_path(path)
    fail!("input must be a canonical regular file") if File.symlink?(full) || !File.file?(full) || File.realpath(full) != full
    parent = File.dirname(full)
    fail!("input parent must be canonical") if File.symlink?(parent) || !Dir.exists?(parent) || File.realpath(parent) != parent
    fail!("input parent is outside the fixed W228 evidence root") unless parent.starts_with?(EVIDENCE_PREFIX) && File.dirname(parent) == "/private/tmp"
    fail!("input exceeds 1 MiB") if File.size(full) > 1_048_576
    JSON.parse(File.read(full))
  end

  private def safe_store(path : String) : String
    full = File.expand_path(path)
    fail!("store root must be a canonical directory") if File.symlink?(full) || !Dir.exists?(full) || File.realpath(full) != full
    native_root = File.dirname(File.dirname(full))
    fail!("native root must be canonical") if File.symlink?(native_root) || !Dir.exists?(native_root) || File.realpath(native_root) != native_root
    fail!("store root is outside the fixed W228 native layout") unless native_root.starts_with?(NATIVE_PREFIX) && full == File.join(native_root, "stores", "catalog")
    full
  end

  private def validate_ids!(input : JSON::Any, key : String, expected : Array(String)) : Array(JSON::Any)
    entries = input[key].as_a
    ids = entries.map { |entry| entry["id"].as_s }
    fail!("#{key} roster/order differs from the bounded fixture") unless ids == expected
    entries
  end

  private def reference_json(reference : CrystalClick::OfflineTableReference) : JSON::Any
    JSON::Any.new({
      "database"           => json_string(reference.database),
      "name"               => json_string(reference.name),
      "database_qualified" => JSON::Any.new(reference.database_qualified?),
    } of String => JSON::Any)
  end

  private def data_guard(table : CrystalClick::OfflineTable) : JSON::Any
    part_inventory = "unexpected_success"
    begin
      table.part_candidates
    rescue ex : CrystalClick::UnsupportedFormatError
      part_inventory = "unsupported"
    end

    callbacks = 0
    row_scan = "unexpected_success"
    begin
      table.scan_typed(["k"]) do |_batch|
        callbacks += 1
        nil
      end
    rescue ex : CrystalClick::UnsupportedFormatError
      row_scan = "unsupported"
    end

    JSON::Any.new({
      "part_inventory" => json_string(part_inventory),
      "row_scan"       => json_string(row_scan),
      "callbacks"      => JSON::Any.new(callbacks.to_i64),
    } of String => JSON::Any)
  end

  private def view_record(catalog : CrystalClick::OfflineCatalog, entry : JSON::Any) : JSON::Any
    id = entry["id"].as_s
    database = entry["database"].as_s
    name = entry["name"].as_s
    table = catalog.table(database, name)
    fail!("#{id} is not classified as a materialized view") unless table.kind == :materialized_view && table.engine == "MaterializedView"
    descriptor = table.materialized_view || fail!("#{id} has no materialized-view descriptor")
    target = descriptor.target
    target_reference = target.reference
    target_json = JSON::Any.new({
      "kind"      => json_string(target.kind.to_s),
      "reference" => target_reference ? reference_json(target_reference) : JSON::Any.new(nil),
      "uuid"      => nullable_string(target.uuid),
    } of String => JSON::Any)

    sources = descriptor.source_references.map { |reference| reference_json(reference) }
    resolved = catalog.resolve_materialized_view_target(database, name)
    resolved_by_database = catalog.resolve_materialized_view_target(catalog.database(database), name)
    metadata = table.metadata_ddl || fail!("#{id} has no persisted ATTACH DDL")

    JSON::Any.new({
      "id"              => json_string(id),
      "database"        => json_string(database),
      "name"            => json_string(name),
      "kind"            => json_string(table.kind.to_s),
      "engine"          => json_string(table.engine),
      "uuid"            => json_string(table.uuid),
      "metadata_ddl"    => json_string(metadata),
      "metadata_sha256" => json_string(Digest::SHA256.hexdigest(metadata)),
      "descriptor"      => JSON::Any.new({
        "declaring_database"         => json_string(descriptor.declaring_database),
        "query"                      => json_string(descriptor.query),
        "inner_engine"               => nullable_string(descriptor.inner_engine),
        "target"                     => target_json,
        "source_references"          => JSON::Any.new(sources),
        "source_references_complete" => JSON::Any.new(descriptor.source_references_complete?),
        "source_references_status"   => json_string(descriptor.source_references_status.to_s),
        "source_references_reason"   => nullable_string(descriptor.source_references_reason),
      } of String => JSON::Any),
      "resolved_target" => JSON::Any.new({
        "name"   => json_string(resolved.name),
        "uuid"   => json_string(resolved.uuid),
        "engine" => json_string(resolved.engine),
      } of String => JSON::Any),
      "resolved_target_by_database" => JSON::Any.new({
        "name"   => json_string(resolved_by_database.name),
        "uuid"   => json_string(resolved_by_database.uuid),
        "engine" => json_string(resolved_by_database.engine),
      } of String => JSON::Any),
      "data_access_guard" => data_guard(table),
    } of String => JSON::Any)
  end

  private def unsupported_control(catalog : CrystalClick::OfflineCatalog, entry : JSON::Any) : JSON::Any
    id = entry["id"].as_s
    database = entry["database"].as_s
    name = entry["name"].as_s
    begin
      table = catalog.table(database, name)
      descriptor = table.materialized_view
      JSON::Any.new({
        "id"             => json_string(id),
        "database"       => json_string(database),
        "name"           => json_string(name),
        "classification" => json_string(descriptor ? "unexpectedly_supported" : "unsupported_no_descriptor"),
        "kind"           => json_string(table.kind.to_s),
        "engine"         => json_string(table.engine),
        "metadata_ddl"   => nullable_string(table.metadata_ddl),
        "error_class"    => JSON::Any.new(nil),
        "error_message"  => JSON::Any.new(nil),
      } of String => JSON::Any)
    rescue ex
      JSON::Any.new({
        "id"             => json_string(id),
        "database"       => json_string(database),
        "name"           => json_string(name),
        "classification" => json_string("unsupported_error"),
        "kind"           => JSON::Any.new(nil),
        "engine"         => JSON::Any.new(nil),
        "metadata_ddl"   => JSON::Any.new(nil),
        "error_class"    => json_string(ex.class.to_s),
        "error_message"  => json_string(ex.message || ""),
      } of String => JSON::Any)
    end
  end

  private def resolver_negative(catalog : CrystalClick::OfflineCatalog, entry : JSON::Any) : JSON::Any
    id = entry["id"].as_s
    database = entry["database"].as_s
    name = entry["name"].as_s
    begin
      resolved = catalog.resolve_materialized_view_target(database, name)
      JSON::Any.new({
        "id"             => json_string(id),
        "database"       => json_string(database),
        "name"           => json_string(name),
        "classification" => json_string("unexpected_success"),
        "resolved_name"  => json_string(resolved.name),
        "resolved_uuid"  => json_string(resolved.uuid),
        "error_class"    => JSON::Any.new(nil),
      } of String => JSON::Any)
    rescue ex
      JSON::Any.new({
        "id"             => json_string(id),
        "database"       => json_string(database),
        "name"           => json_string(name),
        "classification" => json_string("rejected"),
        "resolved_name"  => JSON::Any.new(nil),
        "resolved_uuid"  => JSON::Any.new(nil),
        "error_class"    => json_string(ex.class.to_s),
      } of String => JSON::Any)
    end
  end

  private def projection_control(catalog : CrystalClick::OfflineCatalog, entry : JSON::Any) : JSON::Any
    database = entry["database"].as_s
    name = entry["name"].as_s
    table = catalog.table(database, name)
    projections = table.projections.map do |projection|
      JSON::Any.new({
        "name"       => json_string(projection.name),
        "definition" => json_string(projection.definition),
      } of String => JSON::Any)
    end
    JSON::Any.new({
      "database"     => json_string(database),
      "name"         => json_string(name),
      "kind"         => json_string(table.kind.to_s),
      "engine"       => json_string(table.engine),
      "columns"      => string_array(table.columns.map(&.name)),
      "metadata_ddl" => nullable_string(table.metadata_ddl),
      "projections"  => JSON::Any.new(projections),
    } of String => JSON::Any)
  end

  def run : Nil
    fail!("usage: helper INPUT.json") unless ARGV.size == 1
    input = safe_input(ARGV[0])
    fail!("wrong input format") unless input["format"].as_s == FORMAT_INPUT
    store_root = safe_store(input["store_root"].as_s)
    views = validate_ids!(input, "views", VIEW_IDS)
    controls = validate_ids!(input, "unsupported_controls", CONTROL_IDS)
    negatives = validate_ids!(input, "resolver_negative_cases", NEGATIVE_IDS)
    projection = input["projection_control"]

    catalog = CrystalClick::OfflineCatalog.open(store_root)
    output = JSON::Any.new({
      "format"                  => json_string(FORMAT_OUTPUT),
      "database_names"          => string_array(catalog.database_names),
      "views"                   => JSON::Any.new(views.map { |entry| view_record(catalog, entry) }),
      "unsupported_controls"    => JSON::Any.new(controls.map { |entry| unsupported_control(catalog, entry) }),
      "resolver_negative_cases" => JSON::Any.new(negatives.map { |entry| resolver_negative(catalog, entry) }),
      "projection_control"      => projection_control(catalog, projection),
    } of String => JSON::Any)
    puts output.to_json
  end
end

CheckMaterializedViewMetadataW228.run
