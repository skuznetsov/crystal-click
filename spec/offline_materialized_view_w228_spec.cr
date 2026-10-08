require "./spec_helper"
require "file_utils"

W228_LAB_DATABASE_UUID   = "22800000-0000-4000-8000-000000000001"
W228_OTHER_DATABASE_UUID = "22800000-0000-4000-8000-000000000002"

private def w228_uuid(index : Int32) : String
  "22800000-0000-4000-8000-#{index.to_s(16).rjust(12, '0')}"
end

private def w228_encode_identifier(name : String) : String
  String.build do |io|
    name.each_byte do |byte|
      if byte >= 'a'.ord && byte <= 'z'.ord ||
         byte >= 'A'.ord && byte <= 'Z'.ord ||
         byte >= '0'.ord && byte <= '9'.ord ||
         byte == '_'.ord
        io.write_byte(byte)
      else
        io << '%' << byte.to_s(16).upcase.rjust(2, '0')
      end
    end
  end
end

private def w228_add_database(root : String, name : String, uuid : String) : String
  File.write(
    File.join(root, "metadata", "#{w228_encode_identifier(name)}.sql"),
    "ATTACH DATABASE _ UUID '#{uuid}'\nENGINE = Atomic\n"
  )
  path = File.join(root, "store", uuid[0, 3], uuid)
  FileUtils.mkdir_p(path)
  path
end

private def w228_write_physical_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  columns : String = "`k` UInt64, `v` String",
  projection_definition : String? = nil,
) : String
  projection = projection_definition ? ",\n    PROJECTION by_fake (#{projection_definition})" : ""
  ddl = String.build do |io|
    io << "ATTACH TABLE _ UUID '" << uuid << "'\n(\n    "
    io << columns << projection << "\n)\nENGINE = MergeTree\nORDER BY k\n"
  end
  File.write(File.join(database_path, "#{w228_encode_identifier(name)}.sql"), ddl)

  table_path = File.join(root, "store", uuid[0, 3], uuid)
  unless Dir.exists?(table_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
  end
  table_path
end

private def w228_write_view(
  database_path : String,
  name : String,
  view_uuid : String,
  query : String,
  target_clause : String? = "TO lab.target",
  inner_engine : String? = nil,
  projection_definition : String? = nil,
  column_declarations : String = "`k` UInt64,\n    `v` String",
  inner_order_by : String = "k",
) : Nil
  projection = projection_definition ? ",\n    PROJECTION by_view_key (#{projection_definition})" : ""
  target = target_clause ? " #{target_clause}" : ""
  ddl = String.build do |io|
    io << "ATTACH MATERIALIZED VIEW _ UUID '" << view_uuid << "'" << target << "\n(\n"
    io << "    " << column_declarations << projection << "\n)\n"
    if engine = inner_engine
      io << "ENGINE = " << engine << "\nORDER BY " << inner_order_by << "\n"
    end
    io << "AS " << query
  end
  File.write(File.join(database_path, "#{w228_encode_identifier(name)}.sql"), ddl)
end

private def w228_fixture_root(root : String) : {String, String}
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  lab_path = w228_add_database(root, "lab", W228_LAB_DATABASE_UUID)
  other_path = w228_add_database(root, "other", W228_OTHER_DATABASE_UUID)

  w228_write_physical_table(root, lab_path, "source", w228_uuid(10))
  w228_write_physical_table(root, lab_path, "target", w228_uuid(11))
  # Same unqualified table name in a second database is the context
  # discriminator for an unqualified SELECT reference.
  w228_write_physical_table(root, other_path, "source", w228_uuid(12))
  {lab_path, other_path}
end

describe CrystalClick::OfflineCatalog do
  it "exposes an owned descriptor with exact SELECT text and one complete direct reference" do
    root = File.tempname("crystal-click-offline-mv-w228-direct")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      query = "select `k`, v FROM `lab`.`source` AS s WHERE v = 'TO lab.ghost FROM lab.ghost'"
      w228_write_view(lab_path, "view", w228_uuid(100), query, "TO `lab`.`target`")

      catalog = CrystalClick::OfflineCatalog.open(root)
      table = catalog.table("lab", "view")
      table.responds_to?(:materialized_view).should be_true
      if table.responds_to?(:materialized_view)
        descriptor = table.materialized_view
        descriptor.should_not be_nil
        if view = descriptor
          view.declaring_database.should eq("lab")
          view.query.should eq(query)
          view.inner_engine.should be_nil
          view.source_references_status.should eq(:complete)
          view.source_references_complete?.should be_true
          view.source_references_reason.should be_nil
          view.source_references.map do |reference|
            {reference.database, reference.name, reference.database_qualified?}
          end.should eq([{"lab", "source", true}])

          target = view.target
          target.kind.should eq(:named)
          target.uuid.should be_nil
          if reference = target.reference
            {reference.database, reference.name, reference.database_qualified?}.should eq({"lab", "target", true})
          else
            fail("named MV target reference is missing")
          end

          # Accessors must detach strings, arrays, and nested reference values.
          returned_query = view.query
          returned_query.to_unsafe[0] = 'X'.ord.to_u8
          view.query.should eq(query)
          returned_database = view.declaring_database
          returned_database.to_unsafe[0] = 'X'.ord.to_u8
          view.declaring_database.should eq("lab")
          returned_references = view.source_references
          returned_reference_database = returned_references.first.database
          returned_reference_database.to_unsafe[0] = 'X'.ord.to_u8
          returned_references.clear
          view.source_references.map { |reference| {reference.database, reference.name} }
            .should eq([{"lab", "source"}])

          returned_target_reference = view.target.reference.not_nil!
          returned_target_name = returned_target_reference.name
          returned_target_name.to_unsafe[0] = 'X'.ord.to_u8
          {view.target.reference.not_nil!.database, view.target.reference.not_nil!.name}
            .should eq({"lab", "target"})
        end
      end

      # The MV UUID is metadata identity only; the API does not expose a view
      # store or claim server-side activation.
      File.exists?(File.join(root, "store", w228_uuid(100)[0, 3], w228_uuid(100))).should be_false
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed(["k"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "resolves unqualified sources in the captured database and keeps completeness syntactic" do
    root = File.tempname("crystal-click-offline-mv-w228-context")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      w228_write_view(lab_path, "unqualified", w228_uuid(101), "SELECT k FROM source")
      w228_write_view(lab_path, "missing_source", w228_uuid(102), "SELECT k FROM lab.not_present")

      catalog = CrystalClick::OfflineCatalog.open(root)
      unqualified = catalog.table("lab", "unqualified")
      unqualified.responds_to?(:materialized_view).should be_true
      if unqualified.responds_to?(:materialized_view)
        if view = unqualified.materialized_view
          view.source_references_complete?.should be_true
          view.source_references_status.should eq(:complete)
          view.source_references.map do |reference|
            {reference.database, reference.name, reference.database_qualified?}
          end.should eq([{"lab", "source", false}])
        else
          fail("unqualified MV descriptor is missing")
        end
      end

      # COMPLETE means every direct FROM reference was syntactically
      # accounted for, not that the table exists or is a runtime edge.
      missing = catalog.table("lab", "missing_source")
      missing.responds_to?(:materialized_view).should be_true
      if missing.responds_to?(:materialized_view)
        if view = missing.materialized_view
          view.source_references_complete?.should be_true
          view.source_references.map { |reference| {reference.database, reference.name} }
            .should eq([{"lab", "not_present"}])
        else
          fail("missing-source MV descriptor is missing")
        end
      end
      expect_raises(CrystalClick::InvalidPartError) { catalog.table("lab", "not_present") }
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "parses quoted and escaped table identities without treating identifier or literal keywords as clauses" do
    root = File.tempname("crystal-click-offline-mv-w228-quoted-identities")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      double_quoted_source_name = "source FROM \"TO\""
      double_quoted_target_name = "target TO \"FROM\""
      backtick_source_name = "source FROM `TO` AS SELECT"
      backtick_target_name = "target TO `FROM` AS SELECT"

      w228_write_physical_table(root, lab_path, double_quoted_source_name, w228_uuid(13))
      w228_write_physical_table(root, lab_path, double_quoted_target_name, w228_uuid(14))
      w228_write_physical_table(root, lab_path, backtick_source_name, w228_uuid(15))
      w228_write_physical_table(root, lab_path, backtick_target_name, w228_uuid(16))

      double_quoted_source_token = "\"source FROM \"\"TO\"\"\""
      double_quoted_target_token = "\"target TO \"\"FROM\"\"\""
      backtick_source_token = "`source FROM ``TO`` AS SELECT`"
      backtick_target_token = "`target TO ``FROM`` AS SELECT`"
      double_query = "SELECT k FROM \"lab\".#{double_quoted_source_token} WHERE v = 'literal FROM lab.fake TO other.fake'"
      backtick_query = "SELECT k FROM lab.#{backtick_source_token} WHERE v = 'literal TO lab.fake FROM other.fake'"
      w228_write_view(
        lab_path,
        "double_quoted_view",
        w228_uuid(107),
        double_query,
        "TO \"lab\".#{double_quoted_target_token}"
      )
      w228_write_view(
        lab_path,
        "backtick_escaped_view",
        w228_uuid(108),
        backtick_query,
        "TO lab.#{backtick_target_token}"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      {
        {"double_quoted_view", double_query, double_quoted_source_name, double_quoted_target_name},
        {"backtick_escaped_view", backtick_query, backtick_source_name, backtick_target_name},
      }.each do |view_name, expected_query, expected_source, expected_target|
        table = catalog.table("lab", view_name)
        table.responds_to?(:materialized_view).should be_true
        if table.responds_to?(:materialized_view)
          if view = table.materialized_view
            view.query.should eq(expected_query)
            view.source_references_status.should eq(:complete)
            view.source_references_complete?.should be_true
            view.source_references.map do |reference|
              {reference.database, reference.name, reference.database_qualified?}
            end.should eq([{"lab", expected_source, true}])
            if target_reference = view.target.reference
              {target_reference.database, target_reference.name, target_reference.database_qualified?}
                .should eq({"lab", expected_target, true})
            else
              fail("quoted MV target reference is missing")
            end
          else
            fail("quoted-identity MV descriptor is missing")
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "does not claim complete references for SAMPLE relations or unsupported alias suffixes" do
    root = File.tempname("crystal-click-offline-mv-w228-sample-alias-unknown")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      queries = [
        {"sample_comma_source", "SELECT s.k FROM lab.source AS s SAMPLE 1/2, other.source AS o"},
        {"quoted_alias_suffix", "SELECT s.k FROM lab.source AS \"s\" GARBAGE"},
        {"from_literal_as_alias", "SELECT k FROM 'source' AS s"},
        {"from_literal_bare_alias", "SELECT k FROM 'source' s"},
      ]
      queries.each_with_index do |(name, query), index|
        w228_write_view(lab_path, name, w228_uuid(820 + index), query)
      end

      catalog = CrystalClick::OfflineCatalog.open(root)
      queries.each do |name, _query|
        table = catalog.table("lab", name)
        table.responds_to?(:materialized_view).should be_true
        if table.responds_to?(:materialized_view)
          if view = table.materialized_view
            view.source_references_status.should eq(:unknown)
            view.source_references_complete?.should be_false
            view.source_references.should be_empty
            reason = view.source_references_reason
            reason.should_not be_nil
            reason.not_nil!.should_not be_empty
          else
            fail("unsupported SAMPLE/alias-shape MV descriptor is missing")
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "ignores FROM and TO words inside a projected string literal while retaining the real table" do
    root = File.tempname("crystal-click-offline-mv-w228-literal-projection")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      query = "SELECT 'FROM lab.ghost TO lab.fake' AS note FROM lab.source"
      w228_write_view(
        lab_path,
        "literal_projection",
        w228_uuid(830),
        query,
        target_clause: nil,
        inner_engine: "MergeTree",
        column_declarations: "`note` String",
        inner_order_by: "note"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      table = catalog.table("lab", "literal_projection")
      table.responds_to?(:materialized_view).should be_true
      if table.responds_to?(:materialized_view)
        if view = table.materialized_view
          view.query.should eq(query)
          view.source_references_status.should eq(:complete)
          view.source_references_complete?.should be_true
          view.source_references.map do |reference|
            {reference.database, reference.name, reference.database_qualified?}
          end.should eq([{"lab", "source", true}])
        else
          fail("literal projection MV descriptor is missing")
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "returns UNKNOWN with no partial edges for query shapes outside the direct-reference subset" do
    root = File.tempname("crystal-click-offline-mv-w228-unknown")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      queries = [
        {"cte", "WITH c AS (SELECT k FROM lab.source) SELECT k FROM c"},
        {"join", "SELECT a.k FROM lab.source AS a INNER JOIN other.source AS b ON a.k = b.k"},
        {"nested", "SELECT nested.k FROM (SELECT k FROM lab.source) AS nested"},
        {"table_function", "SELECT number FROM numbers(4)"},
        {"remote_function", "SELECT k FROM remote('host', 'lab', 'source')"},
        {"set_operation", "SELECT k FROM lab.source UNION ALL SELECT k FROM other.source"},
        {"in_subquery", "SELECT k FROM lab.source WHERE k IN (SELECT k FROM other.source)"},
        {"in_table", "SELECT k FROM lab.source WHERE k IN lab.other_source"},
        {"global_in_table", "SELECT k FROM lab.source WHERE k GLOBAL IN lab.other_source"},
      ]
      queries.each_with_index do |(name, query), index|
        w228_write_view(lab_path, name, w228_uuid(200 + index), query)
      end

      catalog = CrystalClick::OfflineCatalog.open(root)
      queries.each do |name, _query|
        table = catalog.table("lab", name)
        table.responds_to?(:materialized_view).should be_true
        if table.responds_to?(:materialized_view)
          if view = table.materialized_view
            view.source_references_status.should eq(:unknown)
            view.source_references_complete?.should be_false
            view.source_references.should be_empty
            reason = view.source_references_reason
            reason.should_not be_nil
            reason.not_nil!.should_not be_empty
          else
            fail("unsupported-shape MV descriptor is missing")
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "classifies source-free SELECTs as complete and rejects lexical SQL controls" do
    root = File.tempname("crystal-click-offline-mv-w228-source-free")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      constant_query = "SELECT 'FROM lab.ghost TO lab.fake' AS note"
      w228_write_view(lab_path, "constant", w228_uuid(300), constant_query)
      w228_write_view(
        lab_path,
        "external_target_with_engine",
        w228_uuid(303),
        "SELECT k FROM lab.source",
        "TO lab.target",
        "MergeTree"
      )
      w228_write_view(
        lab_path,
        "comment_control",
        w228_uuid(301),
        "SELECT k FROM lab.source /* FROM lab.ghost */"
      )
      w228_write_view(lab_path, "statement_control", w228_uuid(302), "SELECT k FROM lab.source; SELECT 1")

      catalog = CrystalClick::OfflineCatalog.open(root)
      constant = catalog.table("lab", "constant")
      constant.responds_to?(:materialized_view).should be_true
      if constant.responds_to?(:materialized_view)
        if view = constant.materialized_view
          view.query.should eq(constant_query)
          view.source_references_status.should eq(:complete)
          view.source_references_complete?.should be_true
          view.source_references.should be_empty
        else
          fail("source-free MV descriptor is missing")
        end
      end

      {"comment_control", "statement_control"}.each do |name|
        expect_raises(CrystalClick::UnsupportedFormatError) { catalog.table("lab", name) }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.table("lab", "external_target_with_engine")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "distinguishes named, inner-UUID, and implicit inner targets without opening view stores" do
    root = File.tempname("crystal-click-offline-mv-w228-targets")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      inner_view_uuid = w228_uuid(400)
      inner_uuid = w228_uuid(401)
      implicit_view_uuid = w228_uuid(402)
      implicit_inner_uuid = w228_uuid(403)

      w228_write_physical_table(root, lab_path, ".inner_id.#{inner_view_uuid}", inner_uuid)
      w228_write_view(lab_path, "inner_view", inner_view_uuid, "SELECT k FROM lab.source", "TO INNER UUID '#{inner_uuid}'", "MergeTree")
      w228_write_physical_table(root, lab_path, ".inner_id.#{implicit_view_uuid}", implicit_inner_uuid)
      w228_write_view(lab_path, "implicit_view", implicit_view_uuid, "SELECT k FROM lab.source", nil, "MergeTree")
      w228_write_view(lab_path, "named_view", w228_uuid(404), "SELECT k FROM lab.source", "TO lab.target", nil)

      catalog = CrystalClick::OfflineCatalog.open(root)
      {
        {"named_view", :named, "target", nil},
        {"inner_view", :inner_uuid, ".inner_id.#{inner_view_uuid}", inner_uuid},
        {"implicit_view", :implicit_inner, ".inner_id.#{implicit_view_uuid}", nil},
      }.each do |view_name, expected_kind, expected_name, expected_uuid|
        view_table = catalog.table("lab", view_name)
        view_table.responds_to?(:materialized_view).should be_true
        if view_table.responds_to?(:materialized_view)
          if descriptor = view_table.materialized_view
            descriptor.target.kind.should eq(expected_kind)
            descriptor.target.uuid.should eq(expected_uuid)
          else
            fail("target-form MV descriptor is missing")
          end
        end

        catalog.responds_to?(:resolve_materialized_view_target).should be_true
        if catalog.responds_to?(:resolve_materialized_view_target)
          resolved = catalog.resolve_materialized_view_target("lab", view_name)
          resolved.name.should eq(expected_name)
          resolved.kind.should eq(:table)
          resolved.engine.should eq("MergeTree")
        end
      end

      # A database-context overload must enforce the same target identity.
      database = catalog.database("lab")
      if catalog.responds_to?(:resolve_materialized_view_target)
        catalog.resolve_materialized_view_target(database, "named_view").name.should eq("target")
      end
      {400, 402, 404}.each do |index|
        view_uuid = w228_uuid(index)
        File.exists?(File.join(root, "store", view_uuid[0, 3], view_uuid)).should be_false
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "requires an optional named-target UUID to match the resolved physical identity" do
    root = File.tempname("crystal-click-offline-mv-w228-named-uuid")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      target_uuid = w228_uuid(11)
      w228_write_view(
        lab_path,
        "named_uuid_match",
        w228_uuid(405),
        "SELECT k FROM lab.source",
        "TO lab.target UUID '#{target_uuid}'"
      )
      w228_write_view(
        lab_path,
        "named_uuid_mismatch",
        w228_uuid(406),
        "SELECT k FROM lab.source",
        "TO lab.target UUID '#{w228_uuid(999)}'"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      table = catalog.table("lab", "named_uuid_match")
      table.responds_to?(:materialized_view).should be_true
      if table.responds_to?(:materialized_view)
        if view = table.materialized_view
          view.target.kind.should eq(:named)
          view.target.uuid.should eq(target_uuid)
        else
          fail("named UUID MV descriptor is missing")
        end
      end

      catalog.responds_to?(:resolve_materialized_view_target).should be_true
      if catalog.responds_to?(:resolve_materialized_view_target)
        catalog.resolve_materialized_view_target("lab", "named_uuid_match").name.should eq("target")
        expect_raises(CrystalClick::InvalidPartError) do
          catalog.resolve_materialized_view_target("lab", "named_uuid_mismatch")
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects foreign and stale OfflineDatabase objects in target resolution" do
    root = File.tempname("crystal-click-offline-mv-w228-database-identity")
    foreign_root = File.tempname("crystal-click-offline-mv-w228-foreign-catalog")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      foreign_lab_path, _foreign_other_path = w228_fixture_root(foreign_root)
      w228_write_view(lab_path, "named_view", w228_uuid(700), "SELECT k FROM lab.source", "TO lab.target")
      w228_write_view(foreign_lab_path, "named_view", w228_uuid(700), "SELECT k FROM lab.source", "TO lab.target")

      catalog = CrystalClick::OfflineCatalog.open(root)
      foreign_catalog = CrystalClick::OfflineCatalog.open(foreign_root)
      foreign_database = foreign_catalog.database("lab")
      catalog.responds_to?(:resolve_materialized_view_target).should be_true
      if catalog.responds_to?(:resolve_materialized_view_target)
        expect_raises(CrystalClick::InvalidPartError) do
          catalog.resolve_materialized_view_target(foreign_database, "named_view")
        end

        stale_database = catalog.database("lab")
        # Rebind the database DDL to a different physical UUID after the
        # caller captures its OfflineDatabase object.
        w228_add_database(root, "lab", w228_uuid(701))
        expect_raises(CrystalClick::InvalidPartError) do
          catalog.resolve_materialized_view_target(stale_database, "named_view")
        end
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(foreign_root)
    end
  end

  it "rejects named and explicit inner targets that resolve to a materialized view rather than a table" do
    root = File.tempname("crystal-click-offline-mv-w228-wrong-target-kind")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      w228_write_view(
        lab_path,
        "named_target_view",
        w228_uuid(710),
        "SELECT k FROM lab.source",
        nil,
        "MergeTree"
      )
      w228_write_view(
        lab_path,
        "named_target_is_view",
        w228_uuid(711),
        "SELECT k FROM lab.source",
        "TO lab.named_target_view"
      )

      inner_owner_uuid = w228_uuid(712)
      inner_view_uuid = w228_uuid(713)
      w228_write_view(
        lab_path,
        ".inner_id.#{inner_owner_uuid}",
        inner_view_uuid,
        "SELECT k FROM lab.source",
        "TO lab.target"
      )
      w228_write_view(
        lab_path,
        "inner_target_is_view",
        inner_owner_uuid,
        "SELECT k FROM lab.source",
        "TO INNER UUID '#{inner_view_uuid}'",
        "MergeTree"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.responds_to?(:resolve_materialized_view_target).should be_true
      if catalog.responds_to?(:resolve_materialized_view_target)
        {"named_target_is_view", "inner_target_is_view"}.each do |view_name|
          expect_raises(CrystalClick::InvalidPartError) do
            catalog.resolve_materialized_view_target("lab", view_name)
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "fails closed on missing, mismatched, or ambiguous physical inner identities" do
    root = File.tempname("crystal-click-offline-mv-w228-inner-fail-closed")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      missing_view_uuid = w228_uuid(500)
      missing_target_uuid = w228_uuid(501)
      mismatch_view_uuid = w228_uuid(502)
      mismatch_target_uuid = w228_uuid(503)
      duplicate_view_uuid = w228_uuid(504)
      duplicate_target_uuid = w228_uuid(505)

      # A hidden-name match with a different physical UUID must not satisfy an
      # explicit INNER UUID target.
      w228_write_physical_table(root, lab_path, ".inner_id.#{mismatch_view_uuid}", w228_uuid(506))
      w228_write_physical_table(root, lab_path, "duplicate_inner_a", duplicate_target_uuid)
      w228_write_physical_table(root, lab_path, "duplicate_inner_b", duplicate_target_uuid)
      w228_write_view(lab_path, "missing_inner_view", missing_view_uuid, "SELECT k FROM lab.source", "TO INNER UUID '#{missing_target_uuid}'", "MergeTree")
      w228_write_view(lab_path, "mismatch_inner_view", mismatch_view_uuid, "SELECT k FROM lab.source", "TO INNER UUID '#{mismatch_target_uuid}'", "MergeTree")
      w228_write_view(lab_path, "ambiguous_inner_view", duplicate_view_uuid, "SELECT k FROM lab.source", "TO INNER UUID '#{duplicate_target_uuid}'", "MergeTree")

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.responds_to?(:resolve_materialized_view_target).should be_true
      if catalog.responds_to?(:resolve_materialized_view_target)
        {"missing_inner_view", "mismatch_inner_view", "ambiguous_inner_view"}.each do |name|
          expect_raises(CrystalClick::InvalidPartError) do
            catalog.resolve_materialized_view_target("lab", name)
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects malformed or absent serialized INNER UUID values" do
    root = File.tempname("crystal-click-offline-mv-w228-invalid-inner-uuid")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      w228_write_view(
        lab_path,
        "malformed_inner_uuid",
        w228_uuid(520),
        "SELECT k FROM lab.source",
        "TO INNER UUID 'not-a-uuid'",
        "MergeTree"
      )
      w228_write_view(
        lab_path,
        "empty_inner_uuid",
        w228_uuid(521),
        "SELECT k FROM lab.source",
        "TO INNER UUID ''",
        "MergeTree"
      )
      w228_write_view(
        lab_path,
        "nil_inner_uuid",
        w228_uuid(522),
        "SELECT k FROM lab.source",
        "TO INNER UUID '00000000-0000-0000-0000-000000000000'",
        "MergeTree"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      {"malformed_inner_uuid", "empty_inner_uuid", "nil_inner_uuid"}.each do |view_name|
        expect_raises(CrystalClick::UnsupportedFormatError) { catalog.table("lab", view_name) }
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "detaches descriptor constructor inputs and enforces complete versus unknown invariants" do
    declaring_database = String.build { |io| io << "lab" }
    query = String.build { |io| io << "SELECT k FROM lab.source" }
    engine = String.build { |io| io << "MergeTree" }
    target_database = String.build { |io| io << "lab" }
    target_name = String.build { |io| io << "target" }
    target_uuid = String.build { |io| io << w228_uuid(900) }
    source_database = String.build { |io| io << "lab" }
    source_name = String.build { |io| io << "source" }

    target_reference = CrystalClick::OfflineTableReference.new(target_database, target_name, true)
    target = CrystalClick::OfflineMaterializedViewTarget.named(target_reference, target_uuid)
    source_references = [CrystalClick::OfflineTableReference.new(source_database, source_name, false)]
    view = CrystalClick::OfflineMaterializedView.new(
      declaring_database: declaring_database,
      query: query,
      inner_engine: engine,
      target: target,
      source_references: source_references,
      source_references_status: :complete,
      source_references_reason: nil
    )

    declaring_database.to_unsafe[0] = 'X'.ord.to_u8
    query.to_unsafe[0] = 'X'.ord.to_u8
    engine.to_unsafe[0] = 'X'.ord.to_u8
    target_database.to_unsafe[0] = 'X'.ord.to_u8
    target_name.to_unsafe[0] = 'X'.ord.to_u8
    target_uuid.to_unsafe[0] = 'X'.ord.to_u8
    source_database.to_unsafe[0] = 'X'.ord.to_u8
    source_name.to_unsafe[0] = 'X'.ord.to_u8
    source_references.clear

    view.declaring_database.should eq("lab")
    view.query.should eq("SELECT k FROM lab.source")
    view.inner_engine.should eq("MergeTree")
    view.source_references_status.should eq(:complete)
    view.source_references_reason.should be_nil
    view.source_references.map do |reference|
      {reference.database, reference.name, reference.database_qualified?}
    end.should eq([{"lab", "source", false}])
    view.target.uuid.should eq(w228_uuid(900))
    if reference = view.target.reference
      {reference.database, reference.name, reference.database_qualified?}
        .should eq({"lab", "target", true})
    else
      fail("constructor target reference is missing")
    end

    unknown = CrystalClick::OfflineMaterializedView.new(
      declaring_database: "lab",
      query: "SELECT k FROM lab.source UNION ALL SELECT k FROM other.source",
      inner_engine: nil,
      target: CrystalClick::OfflineMaterializedViewTarget.named(
        CrystalClick::OfflineTableReference.new("lab", "target", true)
      ),
      source_references: [] of CrystalClick::OfflineTableReference,
      source_references_status: :unknown,
      source_references_reason: "set operations are outside the direct-reference subset"
    )
    unknown.source_references.should be_empty
    unknown.source_references_status.should eq(:unknown)
    unknown.source_references_reason.should_not be_nil
    unknown.source_references_reason.not_nil!.should_not be_empty

    source_free_complete = CrystalClick::OfflineMaterializedView.new(
      declaring_database: "lab",
      query: "SELECT 1",
      inner_engine: nil,
      target: CrystalClick::OfflineMaterializedViewTarget.named(
        CrystalClick::OfflineTableReference.new("lab", "target", true)
      ),
      source_references: [] of CrystalClick::OfflineTableReference,
      source_references_status: :complete,
      source_references_reason: nil
    )
    source_free_complete.source_references_status.should eq(:complete)
    source_free_complete.source_references.should be_empty

    invariant_target = CrystalClick::OfflineMaterializedViewTarget.named(
      CrystalClick::OfflineTableReference.new("lab", "target", true)
    )
    invariant_source = CrystalClick::OfflineTableReference.new("lab", "source", true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineMaterializedView.new(
        declaring_database: "lab",
        query: "SELECT k FROM lab.source",
        inner_engine: nil,
        target: invariant_target,
        source_references: [invariant_source],
        source_references_status: :unknown,
        source_references_reason: "unsupported shape"
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineMaterializedView.new(
        declaring_database: "lab",
        query: "SELECT k FROM lab.source JOIN other.source ON 1",
        inner_engine: nil,
        target: invariant_target,
        source_references: [] of CrystalClick::OfflineTableReference,
        source_references_status: :unknown,
        source_references_reason: nil
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineMaterializedView.new(
        declaring_database: "lab",
        query: "SELECT k FROM lab.source JOIN other.source ON 1",
        inner_engine: nil,
        target: invariant_target,
        source_references: [] of CrystalClick::OfflineTableReference,
        source_references_status: :unknown,
        source_references_reason: ""
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineMaterializedView.new(
        declaring_database: "lab",
        query: "SELECT k FROM lab.source",
        inner_engine: nil,
        target: invariant_target,
        source_references: [invariant_source],
        source_references_status: :complete,
        source_references_reason: "complete inventory has no reason"
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineMaterializedView.new(
        declaring_database: "lab",
        query: "SELECT k FROM lab.source",
        inner_engine: nil,
        target: invariant_target,
        source_references: [] of CrystalClick::OfflineTableReference,
        source_references_status: :partial,
        source_references_reason: "invalid status"
      )
    end
  end

  it "keeps projection declarations separate from MV query references" do
    root = File.tempname("crystal-click-offline-mv-w228-projection")
    begin
      lab_path, _other_path = w228_fixture_root(root)
      w228_write_view(
        lab_path,
        "projected_view",
        w228_uuid(600),
        "SELECT k FROM lab.source",
        projection_definition: "SELECT k ORDER BY k"
      )
      w228_write_physical_table(
        root,
        lab_path,
        "projected_table",
        w228_uuid(601),
        projection_definition: "SELECT 'FROM lab.ghost' AS note ORDER BY k"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      view_table = catalog.table("lab", "projected_view")
      view_table.responds_to?(:materialized_view).should be_true
      if view_table.responds_to?(:materialized_view)
        if view = view_table.materialized_view
          view.source_references.map { |reference| {reference.database, reference.name} }
            .should eq([{"lab", "source"}])
        else
          fail("projected MV descriptor is missing")
        end
      end
      view_table.projections.map { |projection| {projection.name, projection.definition} }
        .should eq([{"by_view_key", "SELECT k ORDER BY k"}])

      ordinary = catalog.table("lab", "projected_table")
      ordinary.responds_to?(:materialized_view).should be_true
      if ordinary.responds_to?(:materialized_view)
        ordinary.materialized_view.should be_nil
      end
      ordinary.projections.map { |projection| {projection.name, projection.definition} }
        .should eq([{"by_fake", "SELECT 'FROM lab.ghost' AS note ORDER BY k"}])
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
