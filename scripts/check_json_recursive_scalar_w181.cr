require "digest/sha256"
require "json"
require "./support/json_recursive_scalar_w181_cases"

module W181JSONRecursiveScalarFixtures
  extend self

  STATIC_REFUSALS = %w[
    qbit nullable_qbit count numeric_map interval bfloat16 nullable_nothing
  ]
  RUNTIME_REFUSALS = %w[variant dynamic lc_nullable]
  SOURCE_FILES     = %w[
    scripts/support/json_recursive_scalar_w181_cases.cr
    scripts/check_json_recursive_scalar_w181.cr
    scripts/check_json_recursive_scalar_w181.rb
    src/crystal_click/binary_data_type.cr
    src/crystal_click/binary_data_type_codec.cr
    src/crystal_click/binary_json_type.cr
    src/crystal_click/binary_json_type_codec.cr
    src/crystal_click/binary_json_value_codec.cr
    src/crystal_click/binary_json_row.cr
    src/crystal_click/binary_value.cr
    src/crystal_click/binary_value_codec.cr
    src/crystal_click/binary_codec_budget.cr
    src/crystal_click/binary_codec_context.cr
  ]

  def require!(condition : Bool, message : String) : Nil
    raise message unless condition
  end

  def fixture_root(path : String, require_empty : Bool) : String
    require!(!path.empty?, "fixture root path is required")
    expanded = File.expand_path(path)
    require!(!File.symlink?(expanded) && File.directory?(expanded), "fixture root must be an existing plain directory")
    root = File.realpath(expanded)
    tmp_root = File.realpath("/private/tmp")
    require!(root == expanded && File.dirname(root) == tmp_root,
      "fixture root must be a direct child of /private/tmp")
    require!(Dir.children(root).empty?, "fixture output root must be empty") if require_empty
    root
  end

  def input_root(path : String) : String
    require!(!path.empty?, "input root path is required")
    expanded = File.expand_path(path)
    require!(!File.symlink?(expanded) && File.directory?(expanded), "input root must be an existing plain directory")
    root = File.realpath(expanded)
    tmp_root = File.realpath("/private/tmp")
    require!(root == expanded && File.dirname(root) == tmp_root,
      "input root must be a direct child of /private/tmp")
    root
  end

  def plain_file!(path : String, label : String) : Nil
    require!(File.file?(path) && !File.symlink?(path), "#{label} must be a plain file")
  end

  def plain_directory!(path : String, label : String) : Nil
    require!(File.directory?(path) && !File.symlink?(path), "#{label} must be a plain directory")
  end

  def bytes_at(path : String, label : String) : Bytes
    plain_file!(path, label)
    File.read(path).to_slice.dup
  end

  def hash_bytes(bytes : Bytes) : String
    Digest::SHA256.hexdigest(bytes)
  end

  def source_hashes : Array(Tuple(String, String))
    SOURCE_FILES.map do |relative|
      path = File.join(Dir.current, relative)
      plain_file!(path, "source file #{relative}")
      {relative, hash_bytes(File.read(path).to_slice)}
    end
  end

  def profile_manifest(profile : W181JSONRecursiveScalarCases::Profile) : NamedTuple(
    id: String,
    type: String,
    descriptor: String,
    row: String,
    descriptor_bytes: Int32,
    row_bytes: Int32,
    descriptor_sha256: String,
    row_sha256: String,
  )
    {
      id:                profile.id,
      type:              profile.type_name,
      descriptor:        "#{profile.id}/descriptor.bin",
      row:               "#{profile.id}/row.bin",
      descriptor_bytes:  profile.descriptor.size,
      row_bytes:         profile.row.size,
      descriptor_sha256: hash_bytes(profile.descriptor),
      row_sha256:        hash_bytes(profile.row),
    }
  end

  def write_manifest(root : String, profiles : Array(W181JSONRecursiveScalarCases::Profile)) : Nil
    hashes = source_hashes
    JSON.build do |json|
      json.object do
        json.field "version", 1
        json.field "scope", "finite JSON scalar RowBinary fixtures; not a complete grammar or persisted-part claim"
        json.field "source_revision", "W181 fixture generation based on #{W181JSONRecursiveScalarCases::BASELINE_REVISION}; exact source_sha256 below"
        json.field "source_sha256" do
          json.object do
            hashes.each do |relative, sha256|
              json.field relative, sha256
            end
          end
        end
        json.field "oracle" do
          json.object do
            json.field "kind", "independently captured native ClickHouse RowBinaryWithNamesAndTypes"
            json.field "version", W181JSONRecursiveScalarCases::ORACLE_VERSION
            json.field "build_hash", W181JSONRecursiveScalarCases::ORACLE_BUILD_HASH
            json.field "binary_sha256", W181JSONRecursiveScalarCases::ORACLE_BINARY_SHA256
          end
        end
        json.field "codec_source", "CrystalClick::BinaryDataTypeCodec and CrystalClick::BinaryValueCodec"
        json.field "profiles" do
          json.array do
            profiles.each do |profile|
              manifest_profile = profile_manifest(profile)
              json.object do
                json.field "id", manifest_profile[:id]
                json.field "type", manifest_profile[:type]
                json.field "descriptor", manifest_profile[:descriptor]
                json.field "row", manifest_profile[:row]
                json.field "descriptor_bytes", manifest_profile[:descriptor_bytes]
                json.field "row_bytes", manifest_profile[:row_bytes]
                json.field "descriptor_sha256", manifest_profile[:descriptor_sha256]
                json.field "row_sha256", manifest_profile[:row_sha256]
              end
            end
          end
        end
      end
    end.tap { |manifest| File.write(File.join(root, "manifest.json"), manifest + "\n") }
  end

  def emit_fixtures(path : String) : Nil
    root = fixture_root(path, true)
    profiles = W181JSONRecursiveScalarCases.build_profiles
    profiles.each do |profile|
      descriptor = CrystalClick::BinaryDataTypeCodec.encode(profile.type)
      row = CrystalClick::BinaryValueCodec.encode_value(profile.value)
      W181JSONRecursiveScalarCases.verify_profile_codecs!(profile, descriptor, row)
      directory = File.join(root, profile.id)
      Dir.mkdir(directory, 0o700)
      File.write(File.join(directory, "descriptor.bin"), descriptor)
      File.write(File.join(directory, "row.bin"), row)
    end
    write_manifest(root, profiles)
    puts "PASS W181 library fixtures: #{profiles.size} finite profiles"
  end

  def verify_library(path : String) : Nil
    root = input_root(path)
    profiles = W181JSONRecursiveScalarCases.build_profiles
    expected_roster = profiles.map(&.id).sort + ["manifest.json"]
    require!(Dir.children(root).sort == expected_roster.sort, "library fixture roster differs")

    manifest_path = File.join(root, "manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    require!(manifest["version"].as_i == 1, "library manifest version differs")
    require!(manifest["scope"].as_s == "finite JSON scalar RowBinary fixtures; not a complete grammar or persisted-part claim",
      "library manifest scope differs")
    require!(manifest["source_revision"].as_s ==
             "W181 fixture generation based on #{W181JSONRecursiveScalarCases::BASELINE_REVISION}; exact source_sha256 below",
      "library manifest source revision differs")
    source_object = manifest["source_sha256"]
    source_hashes.each do |relative, expected_sha|
      require!(source_object[relative].as_s == expected_sha, "source hash differs for #{relative}")
    end

    oracle = manifest["oracle"]
    require!(oracle["version"].as_s == W181JSONRecursiveScalarCases::ORACLE_VERSION &&
             oracle["build_hash"].as_s == W181JSONRecursiveScalarCases::ORACLE_BUILD_HASH &&
             oracle["binary_sha256"].as_s == W181JSONRecursiveScalarCases::ORACLE_BINARY_SHA256,
      "pinned native oracle provenance differs")
    entries = manifest["profiles"].as_a
    require!(entries.size == profiles.size, "library manifest profile count differs")

    profiles.each_with_index do |profile, index|
      entry = entries[index]
      require!(entry["id"].as_s == profile.id && entry["type"].as_s == profile.type_name,
        "#{profile.id}: library manifest identity differs")
      directory = File.join(root, profile.id)
      plain_directory!(directory, "#{profile.id} profile directory")
      require!(Dir.children(directory).sort == %w[descriptor.bin row.bin],
        "#{profile.id}: unexpected library fixture files")
      descriptor = bytes_at(File.join(directory, "descriptor.bin"), "#{profile.id} descriptor")
      row = bytes_at(File.join(directory, "row.bin"), "#{profile.id} row")
      require!(entry["descriptor"].as_s == "#{profile.id}/descriptor.bin" &&
               entry["row"].as_s == "#{profile.id}/row.bin" &&
               entry["descriptor_bytes"].as_i == descriptor.size &&
               entry["row_bytes"].as_i == row.size &&
               entry["descriptor_sha256"].as_s == hash_bytes(descriptor) &&
               entry["row_sha256"].as_s == hash_bytes(row),
        "#{profile.id}: library manifest wire hashes differ")
      W181JSONRecursiveScalarCases.verify_profile_codecs!(profile, descriptor, row)
    end
    puts "PASS W181 library fixtures: #{profiles.size} independent literals, accessors, and round trips"
  end

  def verify_stock(path : String) : Nil
    root = input_root(path)
    profiles = W181JSONRecursiveScalarCases.build_profiles
    summary_path = File.join(root, "summary.json")
    plain_file!(summary_path, "native oracle summary")
    summary = JSON.parse(File.read(summary_path))
    require!(summary["finite_profile_count"].as_i == profiles.size &&
             summary["profiles_ok"].as_i == profiles.size &&
             summary["runtime_pin_ok"].as_bool,
      "native oracle summary does not show all profiles and the pinned runtime")
    require!(summary["runtime_sha256_before"].as_s == W181JSONRecursiveScalarCases::ORACLE_BINARY_SHA256 &&
             summary["runtime_sha256_after"].as_s == W181JSONRecursiveScalarCases::ORACLE_BINARY_SHA256,
      "native oracle runtime hash differs from the pin")

    result_entries = summary["profiles"].as_a
    require!(result_entries.size == profiles.size, "native oracle summary profile roster differs")
    profiles.each_with_index do |profile, index|
      result = result_entries[index]
      require!(result["id"].as_s == profile.id && result["type"].as_s == profile.type_name &&
               result["stock_wire_exact"].as_bool,
        "#{profile.id}: native oracle profile was not an exact stock capture")
      require!(result["expected_descriptor_hex"].as_s == profile.descriptor.hexstring.downcase &&
               result["expected_row_hex"].as_s == profile.row.hexstring.downcase,
        "#{profile.id}: native oracle summary literal differs")
      directory = File.join(root, profile.id)
      plain_directory!(directory, "#{profile.id} native profile directory")
      descriptor = bytes_at(File.join(directory, "descriptor.bin"), "#{profile.id} native descriptor")
      row = bytes_at(File.join(directory, "row.bin"), "#{profile.id} native row")
      literal_row = bytes_at(File.join(directory, "literal-row.bin"), "#{profile.id} independently authored literal row")
      require!(descriptor == profile.descriptor && row == profile.row && literal_row == profile.row,
        "#{profile.id}: native descriptor or row differs from the independent literal")
      W181JSONRecursiveScalarCases.verify_profile_codecs!(profile, descriptor, row)
    end

    rejection_entries = summary["expected_rejections"].as_a
    require!(rejection_entries.size == STATIC_REFUSALS.size + RUNTIME_REFUSALS.size,
      "native oracle expected-rejection roster differs")
    expected_ids = STATIC_REFUSALS + RUNTIME_REFUSALS
    rejection_entries.each_with_index do |entry, index|
      require!(entry["id"].as_s == expected_ids[index] && entry["expected_refusal"].as_bool,
        "native oracle rejection #{expected_ids[index]} was not the expected refusal")
      expected_exit = index < STATIC_REFUSALS.size ? 43 : 36
      expected_boundary = index < STATIC_REFUSALS.size ? "json_static_schema" : "dynamic_actual_roster"
      require!(entry["expected_exit"].as_i == expected_exit &&
               entry["refusal_boundary"].as_s == expected_boundary,
        "native oracle rejection classification differs for #{expected_ids[index]}")
    end
    puts "PASS W181 native stock fixtures: #{profiles.size} positive literals and #{rejection_entries.size} scoped refusals"
  end
end

unless ARGV.size == 2
  raise "usage: crystal run scripts/check_json_recursive_scalar_w181.cr -- --emit-fixtures EMPTY_TMP_ROOT | --verify-library FIXTURE_ROOT | --verify-stock NATIVE_EVIDENCE_ROOT"
end

case ARGV[0]
when "--emit-fixtures"
  W181JSONRecursiveScalarFixtures.emit_fixtures(ARGV[1])
when "--verify-library"
  W181JSONRecursiveScalarFixtures.verify_library(ARGV[1])
when "--verify-stock"
  W181JSONRecursiveScalarFixtures.verify_stock(ARGV[1])
else
  raise "unknown W181 JSON recursive scalar mode: #{ARGV[0]}"
end
