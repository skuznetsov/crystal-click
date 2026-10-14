require "../src/crystal_click"
require "./support/compact_part_writer_w279_native_fixture"
require "digest/sha256"
require "json"

module CrystalClick
  # W279-only read access to the parser-retained, per-mark Dynamic child-owner
  # maps. The maps themselves and their parser-produced prefixes are not copied
  # or reconstructed.
  class CompactStaticJsonPreparedContext
    def w279_typed_json_context_at(index : Int) : ObjectDocumentTypedDynamicJsonReadContext?
      @typed_json_contexts[index]?
    end
  end
end

module CompactChildJsonWriterW279Helper
  extend self
  alias Fixture = CompactPartWriterW279NativeFixture

  FORMAT         = "compact_child_json_writer_w279_helper_v1"
  MAX_FILES      = 192
  MAX_PART_BYTES = 64_i64 * 1024_i64 * 1024_i64
  MAX_FILE_BYTES = 64_i64 * 1024_i64 * 1024_i64

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write, read, or audit")
    report = case action
             when "write"
               unless args.size == 7
                 raise ArgumentError.new("usage: helper write DEST map|map_with_buckets|advanced|advanced_chunked mrk3|mrk4 plain|compressed basic|compact s0|s1")
               end
               write_part(args[1], args[2], args[3], args[4], args[5], args[6])
             when "read"
               unless args.size == 7
                 raise ArgumentError.new("usage: helper read PART map|map_with_buckets|advanced|advanced_chunked s0|s1 COLUMN|all FIRST_MARK MARK_COUNT")
               end
               column_name = args[4] == "all" ? nil : args[4]
               selected_report(validate_part(args[1]), args[2], args[3], "read", column_name, args[5].to_i32, args[6].to_i32)
             when "audit"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper audit PART map|map_with_buckets|advanced|advanced_chunked s0|s1")
               end
               selected_report(validate_part(args[1]), args[2], args[3], "audit", nil, 0, CompactPartWriterW279NativeFixture::MARK_COUNT)
             else
               raise ArgumentError.new("unknown W279 helper action: #{action}")
             end
    report.to_json
  end

  private def write_part(
    destination : String,
    layout_name : String,
    mark_name : String,
    compression_name : String,
    mode_name : String,
    profile_name : String,
  ) : JSON::Any
    shared_version = shared_version(layout_name)
    expected_profile = profile(profile_name)
    mark = case mark_name
           when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
           when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
           else             raise ArgumentError.new("W279 mark format must be mrk3 or mrk4")
           end
    compressed = case compression_name
                 when "plain"      then false
                 when "compressed" then true
                 else                   raise ArgumentError.new("W279 mark compression must be plain or compressed")
                 end
    mode = case mode_name
           when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
           when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
           else                raise ArgumentError.new("W279 discriminator mode must be basic or compact")
           end

    part = validate_new_destination(destination)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      Fixture::KEY_NAME,
      Fixture.keys,
      Fixture.columns(shared_version),
      rows_per_mark: Fixture::ROWS_PER_MARK,
      frame_bytes: Fixture::FRAME_BYTES,
      mark_format: mark,
      variant_discriminator_mode: mode,
      compress_marks: compressed,
      profile: expected_profile,
    )
    selected_report(
      part,
      layout_name,
      profile_name,
      "write",
      nil,
      0,
      Fixture::MARK_COUNT,
      requested_mark_format: mark_name,
      requested_compression: compression_name,
      requested_mode: mode_name,
    )
  end

  private def selected_report(
    part : String,
    layout_name : String,
    profile_name : String,
    action : String,
    column_name : String?,
    first_mark : Int32,
    mark_count : Int32,
    requested_mark_format : String? = nil,
    requested_compression : String? = nil,
    requested_mode : String? = nil,
  ) : JSON::Any
    version = shared_version(layout_name)
    layout = layout_info(layout_name)
    expected_profile = profile(profile_name)
    mark_total = Fixture::MARK_COUNT
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= mark_total && mark_count <= mark_total - first_mark
      raise ArgumentError.new("W279 selected mark window is outside the four data marks")
    end

    selected_names = Fixture::COLUMN_NAMES
    if selected = column_name
      unless selected_names.includes?(selected)
        raise ArgumentError.new("W279 selected column is outside the fixed fixture")
      end
      selected_names = [selected]
    end

    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    mark_format = physical.mode.mrk3? ? "mrk3" : (physical.mode.mrk4? ? "mrk4" : "unsupported")
    unless mark_format == "mrk3" || mark_format == "mrk4"
      raise CrystalClick::UnsupportedFormatError.new("W279 part has an unsupported Compact mark format")
    end
    if requested_mark_format && requested_mark_format != mark_format
      raise CrystalClick::CorruptPartError.new("W279 written mark format differs from request")
    end
    unless physical.row_count == Fixture::ROW_COUNT.to_u64 &&
           physical.mark_row_counts == Array(UInt64).new(mark_total, Fixture::ROWS_PER_MARK.to_u64)
      raise CrystalClick::CorruptPartError.new("W279 physical row or data-mark grid differs from fixture")
    end

    columns = Array(JSON::Any).new
    child_headers = Array(JSON::Any).new
    selected_names.each do |name|
      depth = Fixture.depth_for(name)
      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(part, name, Fixture.declared_json_type)
      unless reader.schema_declaration == Fixture.declared_json_type.name && reader.ordinary_profile == expected_profile
        raise CrystalClick::UnsupportedFormatError.new("W279 static JSON reader declaration/profile differs for #{name}")
      end
      marks = reader.read_marks(first_mark, mark_count)
      expected_rows = Fixture.rows(name)[first_mark * Fixture::ROWS_PER_MARK, mark_count * Fixture::ROWS_PER_MARK]
      signatures = marks.flatten.map { |document| object_signature(document) }
      expected_signatures = expected_rows.map { |value| storage_signature(value) }
      unless signatures == expected_signatures
        raise CrystalClick::CorruptPartError.new("W279 local JSON read differs from the independent fixed fixture for #{name}")
      end
      columns << json({
        "name"                    => name,
        "type"                    => reader.schema_declaration,
        "profile"                 => reader.ordinary_profile.with_size_stream? ? "with_size_stream" : "single_stream",
        "mark_row_counts"         => reader.mark_row_counts,
        "signatures"              => signatures,
        "physical_stream_names"   => reader.physical_stream_names,
        "selected_checksum_names" => reader.selected_checksum_names,
      })
      child_headers.concat(capture_child_headers(
        part,
        physical,
        reader,
        marks,
        name,
        depth,
        first_mark,
        expected_profile,
        layout,
        mark_format,
      ))
    end

    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    keys = key_reader.read_marks(first_mark, mark_count).flatten.map(&.as_uint64)
    expected_keys = Fixture.keys[first_mark * Fixture::ROWS_PER_MARK, mark_count * Fixture::ROWS_PER_MARK].to_a
    unless keys == expected_keys
      raise CrystalClick::CorruptPartError.new("W279 helper key read differs from its fixed fixture")
    end

    metadata_text = read_bounded_file(part, "serialization.json", 4_i64 * 1024_i64 * 1024_i64)
    metadata = JSON.parse(metadata_text).as_h
    info_version = metadata["version"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W279 serialization metadata version is absent")
    propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) || false
    versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise CrystalClick::CorruptPartError.new("W279 String version roster is absent")
    string_version = versions["string"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W279 String version is absent")
    expected_string_version = expected_profile.with_size_stream? ? 1 : 0
    unless info_version == 1 && string_version == expected_string_version && propagated
      raise CrystalClick::UnsupportedFormatError.new("W279 metadata does not match the propagated String profile")
    end
    metadata_report = {
      "version"                                                => info_version,
      "string_version"                                         => string_version,
      "propagate_types_serialization_versions_to_nested_types" => propagated,
      "raw"                                                    => metadata_text,
    }

    checksums = CrystalClick::PartChecksums.open(part)
    mark_file = physical.marks_name
    if compression = requested_compression
      entry = checksums.entry(mark_file)
      unless entry && entry.not_nil!.compressed == (compression == "compressed")
        raise CrystalClick::CorruptPartError.new("W279 mark compression differs from request")
      end
    end
    roster = physical.physical_roster.map do |slot|
      {"index" => slot.index, "column" => slot.column_name, "stream" => slot.stream_name}
    end
    checksum_entries = checksums.entries.keys.sort.map do |name|
      entry = checksums.entry(name).not_nil!
      {"name" => name, "physical_size" => entry.physical_size, "compressed" => entry.compressed,
       "uncompressed_size" => entry.uncompressed_size}
    end
    files = inventory(part)
    json({
      "format"                         => FORMAT,
      "action"                         => action,
      "status"                         => "ok",
      "part_path"                      => part,
      "shared_version"                 => layout_name,
      "shared_version_value"           => version,
      "effective_bucket_count"         => layout[1],
      "profile"                        => profile_name,
      "mark_format"                    => mark_format,
      "requested_mark_format"          => requested_mark_format,
      "requested_compression"          => requested_compression,
      "requested_mode"                 => requested_mode,
      "first_mark"                     => first_mark,
      "selected_mark_count"            => mark_count,
      "row_count"                      => physical.row_count,
      "data_mark_count"                => physical.granule_count,
      "mark_row_counts"                => physical.mark_row_counts,
      "keys"                           => keys,
      "columns"                        => columns,
      "physical_roster"                => roster,
      "serialization_metadata"         => metadata_report,
      "marks_file"                     => mark_file,
      "files"                          => files,
      "checksums"                      => checksum_entries,
      "child_headers"                  => child_headers,
      "child_header_observation_count" => child_headers.size,
      "zero_occurrence_header_count"   => child_headers.count { |header| header["actual_count"].as_i == 0 },
      "eof_zero_observations"          => first_mark == mark_total && mark_count == 0 && child_headers.empty?,
    })
  end

  private def capture_child_headers(
    part : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    reader : CrystalClick::CompactStaticJsonBulkColumnReader,
    marks : Array(Array(CrystalClick::ObjectDocument)),
    column_name : String,
    depth : Int32,
    first_mark : Int32,
    expected_profile : CrystalClick::BinaryBulkProfile,
    expected_layout : Tuple(UInt64, Int32),
    mark_format : String,
  ) : Array(JSON::Any)
    prepared = reader.prepared_context
    unless prepared.mark_count == CompactPartWriterW279NativeFixture::MARK_COUNT
      raise CrystalClick::CorruptPartError.new("W279 prepared metadata lost the four-mark physical grid")
    end
    callback_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(column_name, CompactPartWriterW279NativeFixture::PAYLOAD_PATH)
    dynamic_callback_name = CrystalClick::PhysicalStreamName.append_literal(callback_prefix, ".dynamic_structure")
    output = Array(JSON::Any).new(marks.size)

    marks.each_with_index do |documents, selected_index|
      mark = first_mark + selected_index
      parent_bytes = prepared.object_prefix_bytes_at(mark)
      parent_object = CrystalClick::ObjectStructureCodec.decode(parent_bytes)
      unless parent_object.version == 4_u64 &&
             parent_object.shared_data_version == expected_layout[0] &&
             parent_object.bucket_count == expected_layout[1].to_u64
        raise CrystalClick::CorruptPartError.new("W279 root Object header does not physically match the selected shared layout")
      end

      dynamic_bytes = prepared.dynamic_prefix_bytes_at(mark, dynamic_callback_name)
      dynamic_structure = CrystalClick::DynamicStructureCodec.decode(dynamic_bytes)
      unless dynamic_structure.version == CrystalClick::DynamicStructure::VERSION_V3 &&
             dynamic_structure.type_count == 1
        raise CrystalClick::CorruptPartError.new("W279 root payload Dynamic prefix is not one registered V3 actual type")
      end

      owner = prepared.w279_typed_json_context_at(mark) ||
              raise(CrystalClick::CorruptPartError.new("W279 mark is missing the parser-retained typed-Dynamic JSON owner"))
      plans = owner.leaf_plans_for(CompactPartWriterW279NativeFixture::PAYLOAD_PATH)
      prefixes = owner.prefixes_for(CompactPartWriterW279NativeFixture::PAYLOAD_PATH)
      unless plans.size == 1 && prefixes.size == 1
        raise CrystalClick::CorruptPartError.new("W279 typed-Dynamic JSON child roster is not exactly one bound leaf")
      end
      key = plans[0][0]
      child_prefix = prefixes[key]? || raise(CrystalClick::CorruptPartError.new("W279 exact child leaf key has no parser-retained Object prefix"))
      unless child_prefix.key == key && key.dynamic_site == "root" &&
             key.descriptor_child_path == CompactPartWriterW279NativeFixture.leaf_descriptor_child_path(depth)
        raise CrystalClick::CorruptPartError.new("W279 inline Object prefix is not bound to the expected Array-chain leaf identity")
      end
      canonical_names = dynamic_structure.canonical_variant_names
      actual_type = canonical_names[key.canonical_arm_index]? ||
                    raise(CrystalClick::CorruptPartError.new("W279 child key arm index is outside the parsed parent Dynamic roster"))
      unless actual_type == CompactPartWriterW279NativeFixture.actual_type(depth).name &&
             actual_type != CrystalClick::DynamicStructure::SHARED_VARIANT_NAME
        raise CrystalClick::CorruptPartError.new("W279 child key does not identify the expected registered Dynamic actual")
      end
      unless dynamic_structure.canonical_index_for(CompactPartWriterW279NativeFixture.actual_type(depth)) == key.canonical_arm_index
        raise CrystalClick::CorruptPartError.new("W279 child key canonical arm index differs from the parsed Dynamic type")
      end

      child_plan = child_prefix.physical_plan
      canonical_prefix = CrystalClick::ObjectDocumentInlineCallbackOrder.canonical_root_prefix(child_plan)
      unless canonical_prefix == child_prefix.physical_prefix
        raise CrystalClick::CorruptPartError.new("W279 inline child escaped prefix differs from its bound physical plan")
      end
      object_stream_name = child_plan.object_structure_stream
      object_callback_name = CrystalClick::PhysicalStreamName.append_literal(child_prefix.callback_prefix, ".object_structure")
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
      callback_matches = [] of Tuple(String, Bytes)
      observed_prefix_name_preview = [] of String
      child_prefix.prefix_callback_count.times do |index|
        name, bytes = child_prefix.prefix_callback_at(index, budget)
        observed_prefix_name_preview << name if observed_prefix_name_preview.size < 8
        callback_matches << {name, bytes} if name == object_stream_name
      end
      unless callback_matches.size == 1
        raise CrystalClick::CorruptPartError.new(
          "W279 parsed child prefix does not retain exactly one canonical ObjectStructure stream #{object_stream_name}; observed prefix names: #{observed_prefix_name_preview.join(", ")}",
        )
      end
      captured_prefix_name, header_bytes = callback_matches[0]
      child_object = child_prefix.plan.structures.object
      child_bucket_count = CompactPartWriterW279NativeFixture.bucket_count_for(child_object.shared_data_version)
      unless child_object.version == 4_u64 &&
             child_object.shared_data_version == parent_object.shared_data_version &&
             child_object.bucket_count == child_bucket_count &&
             child_object.bucket_count == parent_object.bucket_count &&
             child_prefix.nested_context.shared_data_version == parent_object.shared_data_version &&
             child_prefix.nested_context.profile == expected_profile &&
             child_plan.shared_profile == CrystalClick::BinaryBulkProfile.single_stream
        raise CrystalClick::CorruptPartError.new("W279 parsed child Object header changed the parent shared layout or ordinary profile")
      end
      parsed_header_bytes = CrystalClick::BinaryCodecContext.new(
        CrystalClick::BinaryCodecLimits.default,
        header_bytes,
        false,
      )
      parsed_object, parsed_offset = if child_prefix.statistics_context == CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly
                                       CrystalClick::ObjectStructureCodec.read_prefix_without_statistics(parsed_header_bytes)
                                     else
                                       CrystalClick::ObjectStructureCodec.read_with_statistics_offset(parsed_header_bytes)
                                     end
      parsed_header_bytes.ensure_consumed
      unless parsed_object.version == child_object.version &&
             parsed_object.shared_data_version == child_object.shared_data_version &&
             parsed_object.bucket_count == child_object.bucket_count &&
             parsed_object.dynamic_paths == child_object.dynamic_paths &&
             parsed_offset == child_prefix.object_structure_statistics_offset
        raise CrystalClick::CorruptPartError.new("W279 original child ObjectStructure bytes disagree with their parsed callback prefix")
      end

      # Report identities and bytes from the child's completed source capture.
      # The flattened Compact schedule retains body pairs separately; those
      # pairs are not bound into this child prefix and must not stand in for
      # callbacks actually captured by its owner.
      child_body_count = child_prefix.body_callback_count
      child_body_slice_count = child_prefix.body_callback_slice_count
      unless child_body_slice_count == child_body_count
        raise CrystalClick::CorruptPartError.new("W279 child body callback capture is incomplete")
      end
      child_body_roster = Array(JSON::Any).new(child_body_count)
      observed_label_callbacks = Array(JSON::Any).new
      label_stream_roles = child_plan.typed("label").stream_names
      expected_label_streams = label_stream_roles.values.sort
      expected_size_streams = if size_stream = label_stream_roles["root.string_sizes"]?
                                [size_stream] of String
                              else
                                [] of String
                              end
      captured_names = Set(String).new
      child_body_count.times do |index|
        observed_name, observed_bytes = child_prefix.body_callback_at(index, budget)
        slice = child_prefix.body_callback_slice_at(index)
        canonical_name = slice.canonical_name
        callback_name = slice.callback_name
        unless observed_name == canonical_name && slice.bytes == observed_bytes &&
               !canonical_name.empty? && !callback_name.empty? && captured_names.add?(canonical_name)
          raise CrystalClick::CorruptPartError.new("W279 child body callback differs from its exact captured owner slice")
        end
        child_body_roster << json({"canonical_name" => canonical_name, "callback_name" => callback_name})
        if expected_label_streams.includes?(canonical_name)
          observed_label_callbacks << json({
            "canonical_name" => canonical_name,
            "callback_name"  => callback_name,
            "byte_count"     => slice.byte_size,
            "sha256"         => Digest::SHA256.hexdigest(slice.bytes),
          })
        end
      end
      observed_label_names = observed_label_callbacks.map { |entry| entry["canonical_name"].as_s }.sort
      unless observed_label_names == expected_label_streams
        raise CrystalClick::CorruptPartError.new("W279 captured child label callbacks differ from its parsed String stream plan")
      end
      observed_size_names = expected_size_streams.select { |name| observed_label_names.includes?(name) }
      expected_size_count = expected_profile.with_size_stream? ? 1 : 0
      unless expected_size_streams.size == expected_size_count &&
             observed_size_names == expected_size_streams &&
             child_prefix.nested_context.profile == expected_profile
        raise CrystalClick::CorruptPartError.new(
          "W279 captured child String size callbacks differ from parsed plan roles (expected role streams: #{expected_size_streams.join(", ")}; captured label streams: #{observed_label_names.join(", ")}; expected profile: #{profile_name_for(expected_profile)}; child profile: #{profile_name_for(child_prefix.nested_context.profile)})",
        )
      end

      actual_count = 0
      json_leaf_count = 0
      documents.each do |document|
        next unless document.has_path?(CompactPartWriterW279NativeFixture::PAYLOAD_PATH)
        value = document.value_for(CompactPartWriterW279NativeFixture::PAYLOAD_PATH)
        next if value.is_null?
        unless value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC && value.element_count == 1
          raise CrystalClick::CorruptPartError.new("W279 decoded payload is not one selected typed Dynamic child")
        end
        unless value.element_at(0).type.name == actual_type
          raise CrystalClick::CorruptPartError.new("W279 decoded typed Dynamic value differs from its parser-resolved registered actual")
        end
        actual_count += 1
        json_leaf_count += json_leaf_count_in(value.element_at(0))
      end
      expected_actual_count = CompactPartWriterW279NativeFixture.expected_mark_actual_counts(depth)[mark]
      expected_leaf_ids = CompactPartWriterW279NativeFixture.expected_leaf_ids(depth)
      first_row = mark * CompactPartWriterW279NativeFixture::ROWS_PER_MARK
      expected_json_leaf_count = expected_leaf_ids[first_row].size + expected_leaf_ids[first_row + 1].size
      unless actual_count == expected_actual_count && json_leaf_count == expected_json_leaf_count
        raise CrystalClick::CorruptPartError.new("W279 decoded typed-Dynamic actual or JSON-leaf counts differ from the fixed mark witness")
      end

      root_prefix = CrystalClick::PhysicalStreamName.escape(column_name)
      root_object_stream_name = CrystalClick::PhysicalStreamName.append_literal(root_prefix, ".object_structure")
      root_slots = physical.physical_roster.select do |slot|
        slot.column_name == column_name &&
          (mark_format == "mrk3" ? slot.stream_name.nil? : slot.stream_name == root_object_stream_name)
      end
      unless root_slots.size == 1
        raise CrystalClick::CorruptPartError.new("W279 parent ObjectStructure does not resolve to one exact physical owner slot")
      end
      root_slot = root_slots[0]
      child_slot = nil.as(CrystalClick::CompactPhysicalSlot?)
      if mark_format == "mrk4"
        child_slots = physical.physical_roster.select do |slot|
          slot.column_name == column_name && slot.stream_name == object_stream_name
        end
        unless child_slots.size == 1
          raise CrystalClick::CorruptPartError.new("W279 MRK4 child ObjectStructure stream does not resolve to one exact named owner slot")
        end
        child_slot = child_slots[0]
      end

      output << json({
        "parent_column" => column_name,
        "mark"          => mark,
        "actual_type"   => actual_type,
        "leaf_key"      => {
          "dynamic_site"          => key.dynamic_site,
          "canonical_arm_index"   => key.canonical_arm_index,
          "descriptor_child_path" => key.descriptor_child_path,
        },
        "physical_prefix"              => child_prefix.physical_prefix,
        "raw_prefix"                   => child_prefix.callback_prefix,
        "canonical_prefix"             => canonical_prefix,
        "callback_name"                => object_callback_name,
        "captured_prefix_name"         => captured_prefix_name,
        "object_structure_stream_name" => object_stream_name,
        "physical_stream_name"         => mark_format == "mrk4" ? object_stream_name : nil,
        "header_hex"                   => header_bytes.hexstring,
        "header_bytes"                 => header_bytes.size,
        "statistics_context"           => child_prefix.statistics_context == CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly ? "prefix_only" : "complete",
        "parsed"                       => {
          "version"             => child_object.version,
          "shared_data_version" => child_object.shared_data_version,
          "bucket_count"        => child_object.bucket_count,
          "dynamic_paths"       => child_object.dynamic_paths,
          "statistics_offset"   => parsed_offset,
        },
        "parent" => {
          "version"              => parent_object.version,
          "shared_data_version"  => parent_object.shared_data_version,
          "bucket_count"         => parent_object.bucket_count,
          "payload_dynamic_type" => actual_type,
        },
        "parent_physical_slot" => {
          "index"  => root_slot.index,
          "column" => root_slot.column_name,
          "stream" => root_slot.stream_name,
        },
        "mrk3_sequential_owner_slot" => mark_format == "mrk3" ? {
          "index"  => root_slot.index,
          "column" => root_slot.column_name,
          "stream" => root_slot.stream_name,
        } : nil,
        "mrk4_physical_slot" => child_slot.try do |slot|
          {"index" => slot.index, "column" => slot.column_name, "stream" => slot.stream_name}
        end,
        "owner_mode"                      => mark_format == "mrk4" ? "named" : "sequential_inline",
        "actual_count"                    => actual_count,
        "json_leaf_count"                 => json_leaf_count,
        "ordinary_profile"                => profile_name_for(expected_profile),
        "child_profile"                   => profile_name_for(child_prefix.nested_context.profile),
        "child_body_callback_count"       => child_body_roster.size,
        "child_body_callback_roster"      => child_body_roster,
        "child_label_callbacks"           => observed_label_callbacks,
        "child_label_size_callback_count" => observed_size_names.size,
        "child_shared_bucket_count"       => child_plan.shared_bucket_count,
      })
    end
    output
  end

  private def json_leaf_count_in(value : CrystalClick::BinaryValue) : Int32
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_JSON
      1
    when CrystalClick::BinaryDataType::TAG_ARRAY
      total = 0
      value.element_count.times { |index| total += json_leaf_count_in(value.element_at(index)) }
      total
    else
      raise CrystalClick::CorruptPartError.new("W279 Dynamic actual contains a non-JSON leaf in the admitted Array chain")
    end
  end

  private def storage_signature(value : CrystalClick::StorageColumnValue) : String
    if value.object?
      object_signature(value.object_document)
    elsif value.array?
      "Array[#{value.array_values.map { |child| storage_signature(child) }.join(";")}]"
    elsif value.tuple?
      "Tuple(#{value.tuple_values.map { |child| storage_signature(child) }.join(";")})"
    elsif value.bulk?
      binary_signature(value.bulk_value)
    else
      raise CrystalClick::UnsupportedFormatError.new("W279 fixture has an unknown storage value node")
    end
  end

  private def object_signature(document : CrystalClick::ObjectDocument) : String
    fields = document.paths.map do |path|
      "#{path.bytesize}:#{path.to_slice.hexstring}=#{binary_signature(document.value_for(path))}"
    end
    "JSON{#{fields.join(";")}}"
  end

  private def binary_signature(value : CrystalClick::BinaryValue) : String
    return "NULL(#{value.type.name})" if value.is_null?
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      bytes = value.as_string.to_slice
      "S#{bytes.size}:#{bytes.hexstring}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "U64:#{value.as_uint64}"
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      unless value.element_count == 1
        raise CrystalClick::CorruptPartError.new("W279 non-null Dynamic value has no selected child")
      end
      child = value.element_at(0)
      "D<#{child.type.name}>[#{binary_signature(child)}]"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "A<#{value.type.name}>[#{(0...value.element_count).map { |index| binary_signature(value.element_at(index)) }.join(";")}]"
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      fields = row.path_count.times.map do |index|
        path = row.path_at(index)
        nested = row.value_at(index)
        "#{path.bytesize}:#{path.to_slice.hexstring}=#{binary_signature(nested)}"
      end
      "J<#{value.type.name}>{#{fields.join(";")}}"
    else
      raise CrystalClick::UnsupportedFormatError.new("W279 signature has an unsupported leaf type: #{value.type.name}")
    end
  end

  private def layout_info(name : String) : Tuple(UInt64, Int32)
    case name
    when "map"              then {0_u64, 1}
    when "map_with_buckets" then {1_u64, 2}
    when "advanced"         then {2_u64, 2}
    when "advanced_chunked" then {3_u64, 2}
    else                         raise ArgumentError.new("W279 layout must be map, map_with_buckets, advanced, or advanced_chunked")
    end
  end

  private def shared_version(name : String) : UInt64
    layout_info(name)[0]
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "s0" then CrystalClick::BinaryBulkProfile.single_stream
    when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
    else           raise ArgumentError.new("W279 profile must be s0 or s1")
    end
  end

  private def profile_name_for(value : CrystalClick::BinaryBulkProfile) : String
    value.with_size_stream? ? "s1" : "s0"
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W279 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W279 destination parent must be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise ArgumentError.new("W279 part must be an existing canonical non-symlinked directory")
    end
    expanded
  end

  private def inventory(part : String) : Array(JSON::Any)
    paths = [] of String
    Dir.glob("#{part}/**/*", match_hidden: true).each do |path|
      if File.symlink?(path)
        raise CrystalClick::CorruptPartError.new("W279 part inventory contains a symlink")
      elsif File.file?(path)
        paths << path
      elsif !Dir.exists?(path)
        raise CrystalClick::CorruptPartError.new("W279 part inventory contains an unknown filesystem entry")
      end
    end
    paths.sort!
    if paths.size > MAX_FILES
      raise CrystalClick::UnsupportedFormatError.new("W279 part file count exceeds its bound")
    end
    total = 0_i64
    files = paths.map do |path|
      size = File.size(path)
      if size < 0 || size > MAX_FILE_BYTES
        raise CrystalClick::UnsupportedFormatError.new("W279 part file exceeds its per-file bound")
      end
      total += size
      if total > MAX_PART_BYTES
        raise CrystalClick::UnsupportedFormatError.new("W279 part exceeds its total byte bound")
      end
      relative = path.byte_slice(part.bytesize + 1)
      raw = read_bounded_path(path, size)
      json({"path" => relative, "size" => size, "sha256" => Digest::SHA256.hexdigest(raw)})
    end
    files
  end

  private def read_bounded_file(part : String, name : String, limit : Int64) : String
    path = File.join(part, name)
    unless File.file?(path) && !File.symlink?(path)
      raise CrystalClick::CorruptPartError.new("W279 required part file is missing or symlinked: #{name}")
    end
    size = File.size(path)
    if size < 0 || size > limit
      raise CrystalClick::UnsupportedFormatError.new("W279 part file exceeds its read bound: #{name}")
    end
    read_bounded_path(path, size)
  end

  private def read_bounded_path(path : String, size : Int64) : String
    File.open(path, "rb") do |file|
      raw = file.read_string(size)
      unless raw.bytesize.to_i64 == size && file.read_byte.nil?
        raise CrystalClick::CorruptPartError.new("W279 part file changed or exceeded its captured size")
      end
      raw
    end
  end
end

puts CompactChildJsonWriterW279Helper.run(ARGV)
