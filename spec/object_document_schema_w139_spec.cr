require "./spec_helper"

private def w139_schema_limits(
  max_bytes : Int,
  max_nodes : Int = 128,
  max_elements : Int = 128,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 32,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w139_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

private def w139_schema_types : Hash(String, CrystalClick::BinaryDataType)
  types = {
    "datetime_bare"  => CrystalClick::BinaryDataType.datetime,
    "datetime_utc"   => CrystalClick::BinaryDataType.datetime("UTC"),
    "datetime_alias" => CrystalClick::BinaryDataType.datetime("Etc/UTC"),
    "datetime_fixed" => CrystalClick::BinaryDataType.datetime("Fixed/UTC+05:30:00"),
    "time"           => CrystalClick::BinaryDataType.primitive("Time"),
  } of String => CrystalClick::BinaryDataType
  (0..9).each do |scale|
    types["datetime64_#{scale}"] = CrystalClick::BinaryDataType.datetime64(scale)
    types["time64_#{scale}"] = CrystalClick::BinaryDataType.time64(scale)
  end
  types["datetime64_utc"] = CrystalClick::BinaryDataType.datetime64(3, "UTC")
  types["datetime64_alias"] = CrystalClick::BinaryDataType.datetime64(3, "Etc/UTC")
  types["datetime64_fixed"] = CrystalClick::BinaryDataType.datetime64(9, "Fixed/UTC-00:15:00")
  types
end

private def w139_schema_mutate_first_byte(value : String, replacement : UInt8) : Nil
  value.to_unsafe[0] = replacement
end

private def w139_document_budget_charge(document : CrystalClick::ObjectDocument) : UInt64
  budget = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: UInt64::MAX)
  budget.reserve_base(0_u64, 0_u64)
  budget.charge_document(document)
  budget.retained_logical_bytes
end

private class W139MutatingIO < IO
  TARGET_ZONE = "America/New_York"

  @written : Array(UInt8)

  def initialize
    @written = [] of UInt8
  end

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    slice.each { |byte| @written << byte }
    target = TARGET_ZONE.to_slice
    if slice.size == target.size
      matches = true
      target.size.times do |index|
        unless slice[index] == target[index]
          matches = false
          break
        end
      end
      slice[0] = 'X'.ord.to_u8 if matches
    end
    nil
  end

  def rendered : String
    String.build { |io| @written.each { |byte| io.write_byte(byte) } }
  end
end

describe "W139 canonical temporal Object schema" do
  it "round-trips bare and parameterized temporal declarations at every scale" do
    types = w139_schema_types
    schema = CrystalClick::ObjectDocumentSchema.new(types)
    expected_declaration = "JSON(#{types.keys.sort.map { |path| "#{path} #{types[path].name}" }.join(", ")})"
    schema.declaration.should eq(expected_declaration)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected_declaration)
    parsed.declaration.should eq(expected_declaration)
    parsed.typed_paths.should eq(types)
    parsed.validate_plan(w139_schema_plan(types)).should be_nil

    types["datetime_bare"].name.should eq("DateTime")
    types["datetime_utc"].name.should eq("DateTime('UTC')")
    types["datetime64_0"].name.should eq("DateTime64(0)")
    types["datetime64_9"].name.should eq("DateTime64(9)")
    types["datetime64_utc"].name.should eq("DateTime64(3, 'UTC')")
    types["time"].name.should eq("Time")
    types["time64_0"].name.should eq("Time64(0)")
    types["time64_9"].name.should eq("Time64(9)")
  end

  it "preserves exact implicit, UTC, alias, and fixed-offset identity and detached zone names" do
    bare_datetime = CrystalClick::BinaryDataType.datetime
    utc_datetime = CrystalClick::BinaryDataType.datetime("UTC")
    alias_datetime = CrystalClick::BinaryDataType.datetime("Etc/UTC")
    positive_zero = CrystalClick::BinaryDataType.datetime("Fixed/UTC+00:00:00")
    negative_zero = CrystalClick::BinaryDataType.datetime("Fixed/UTC-00:00:00")
    bare_datetime.should_not eq(utc_datetime)
    utc_datetime.should_not eq(alias_datetime)
    positive_zero.should_not eq(negative_zero)

    bare64 = CrystalClick::BinaryDataType.datetime64(3)
    utc64 = CrystalClick::BinaryDataType.datetime64(3, "UTC")
    alias64 = CrystalClick::BinaryDataType.datetime64(3, "Etc/UTC")
    other_scale64 = CrystalClick::BinaryDataType.datetime64(4, "UTC")
    bare64.should_not eq(utc64)
    utc64.should_not eq(alias64)
    utc64.should_not eq(other_scale64)

    source_zone = String.new("America/New_York".to_slice)
    owned = CrystalClick::BinaryDataType.datetime64(9, source_zone)
    w139_schema_mutate_first_byte(source_zone, 'X'.ord.to_u8)
    zone = owned.temporal_type.not_nil!.time_zone?.not_nil!
    zone.name.should eq("America/New_York")
    exposed_name = zone.name
    w139_schema_mutate_first_byte(exposed_name, 'Y'.ord.to_u8)
    zone.name.should eq("America/New_York")
    owned.name.should eq("DateTime64(9, 'America/New_York')")

    schema = CrystalClick::ObjectDocumentSchema.new({
      "bare"           => bare_datetime,
      "utc"            => utc_datetime,
      "alias"          => alias_datetime,
      "fixed_positive" => positive_zero,
      "fixed_negative" => negative_zero,
      "bare64"         => bare64,
      "utc64"          => utc64,
      "alias64"        => alias64,
    })
    detached = schema.typed_paths
    detached_zone = detached["utc64"].temporal_type.not_nil!.time_zone?.not_nil!.name
    w139_schema_mutate_first_byte(detached_zone, 'X'.ord.to_u8)
    schema.typed_paths["utc64"].temporal_type.not_nil!.time_zone?.not_nil!.name.should eq("UTC")
  end

  it "preflights exact aggregate constructor and parser bytes for multiple explicit zones" do
    types = {
      "left"  => CrystalClick::BinaryDataType.datetime("UTC"),
      "right" => CrystalClick::BinaryDataType.datetime64(9, "Etc/UTC"),
    } of String => CrystalClick::BinaryDataType
    declaration = "JSON(left DateTime('UTC'), right DateTime64(9, 'Etc/UTC'))"
    path_bytes = "left".bytesize.to_u64 + "right".bytesize.to_u64
    constructor_bytes = path_bytes + 2_u64 * declaration.bytesize.to_u64

    constructed = CrystalClick::ObjectDocumentSchema.new(
      types,
      limits: w139_schema_limits(constructor_bytes.to_i),
    )
    constructed.declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        types,
        limits: w139_schema_limits((constructor_bytes - 1_u64).to_i),
      )
    end

    leaf_bytes = 0_u64
    types.each_value do |type|
      leaf_bytes += type.name.bytesize.to_u64 + 1_u64
    end
    zone_bytes = "UTC".bytesize.to_u64 + "Etc/UTC".bytesize.to_u64
    parser_bytes = 3_u64 * declaration.bytesize.to_u64 +
                   2_u64 * path_bytes + leaf_bytes + 2_u64 * zone_bytes
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(
      declaration,
      w139_schema_limits(parser_bytes.to_i),
    )
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(types)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w139_schema_limits((parser_bytes - 1_u64).to_i),
      )
    end
  end

  it "rejects aliases, noncanonical parameters, invalid scales, and timezones on Time" do
    malformed = [
      "JSON(v DateTime64)",
      "JSON(v Time64)",
      "JSON(v DateTime(0))",
      "JSON(v Time(0))",
      "JSON(v DateTime64(03))",
      "JSON(v DateTime64(-1))",
      "JSON(v DateTime64(10))",
      "JSON(v Time64(03))",
      "JSON(v Time64(-1))",
      "JSON(v Time64(10))",
      "JSON(v DateTime( 'UTC'))",
      "JSON(v DateTime64(3,'UTC'))",
      "JSON(v DateTime64(3,  'UTC'))",
      "JSON(v DateTime(''))",
      "JSON(v DateTime64(3, ''))",
      "JSON(v DateTime('Definitely/Not_A_Zone'))",
      "JSON(v Time('UTC'))",
      "JSON(v Time64(3, 'UTC'))",
    ]
    malformed.each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end

    [-1, 10].each do |scale|
      expect_raises(ArgumentError) { CrystalClick::BinaryDataType.datetime64(scale) }
      expect_raises(ArgumentError) { CrystalClick::BinaryDataType.time64(scale) }
    end
  end

  it "rejects scale, zone, and same-width integer aliases at schema, plan, and value boundaries" do
    types = {
      "datetime"   => CrystalClick::BinaryDataType.datetime,
      "datetime64" => CrystalClick::BinaryDataType.datetime64(3, "UTC"),
      "time"       => CrystalClick::BinaryDataType.primitive("Time"),
      "time64"     => CrystalClick::BinaryDataType.time64(9),
    } of String => CrystalClick::BinaryDataType
    schema = CrystalClick::ObjectDocumentSchema.new(types)
    schema.validate_plan(w139_schema_plan(types)).should be_nil

    mismatches = [] of Hash(String, CrystalClick::BinaryDataType)
    changed_zone = types.dup
    changed_zone["datetime64"] = CrystalClick::BinaryDataType.datetime64(3, "Etc/UTC")
    mismatches << changed_zone
    changed_implicit_zone = types.dup
    changed_implicit_zone["datetime"] = CrystalClick::BinaryDataType.datetime("UTC")
    mismatches << changed_implicit_zone
    changed_scale = types.dup
    changed_scale["datetime64"] = CrystalClick::BinaryDataType.datetime64(4, "UTC")
    mismatches << changed_scale
    changed_time_scale = types.dup
    changed_time_scale["time64"] = CrystalClick::BinaryDataType.time64(8)
    mismatches << changed_time_scale
    changed_datetime_alias = types.dup
    changed_datetime_alias["datetime"] = CrystalClick::BinaryDataType.primitive("UInt32")
    mismatches << changed_datetime_alias
    changed_time_alias = types.dup
    changed_time_alias["time"] = CrystalClick::BinaryDataType.primitive("Int32")
    mismatches << changed_time_alias
    changed_datetime64_alias = types.dup
    changed_datetime64_alias["datetime64"] = CrystalClick::BinaryDataType.primitive("Int64")
    mismatches << changed_datetime64_alias

    mismatches.each do |other_types|
      expect_raises(ArgumentError) { schema.validate_plan(w139_schema_plan(other_types)) }
    end

    raw32 = Bytes[0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8]
    datetime_value = CrystalClick::BinaryValue.fixed(types["datetime"], raw32)
    uint32_alias = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt32"), raw32)
    datetime_value.bytes.should eq(uint32_alias.bytes)
    datetime_value.type.should_not eq(uint32_alias.type)

    raw64 = Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
    datetime64_value = CrystalClick::BinaryValue.fixed(types["datetime64"], raw64)
    int64_alias = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int64"), raw64)
    datetime64_value.bytes.should eq(int64_alias.bytes)
    datetime64_value.type.should_not eq(int64_alias.type)
  end

  it "charges explicit zone owners and enforces exact then one-short public catalog-budget boundaries" do
    bare_types = {
      "datetime"   => CrystalClick::BinaryDataType.datetime,
      "datetime64" => CrystalClick::BinaryDataType.datetime64(9),
    } of String => CrystalClick::BinaryDataType
    zoned_types = {
      "datetime"   => CrystalClick::BinaryDataType.datetime("UTC"),
      "datetime64" => CrystalClick::BinaryDataType.datetime64(9, "Etc/UTC"),
    } of String => CrystalClick::BinaryDataType
    raw32 = Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8]
    raw64 = Bytes[0x05_u8, 0x06_u8, 0x07_u8, 0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8, 0x0c_u8]
    bare_document = CrystalClick::ObjectDocument.new({
      "datetime"   => CrystalClick::BinaryValue.fixed(bare_types["datetime"], raw32),
      "datetime64" => CrystalClick::BinaryValue.fixed(bare_types["datetime64"], raw64),
    })
    zoned_document = CrystalClick::ObjectDocument.new({
      "datetime"   => CrystalClick::BinaryValue.fixed(zoned_types["datetime"], raw32),
      "datetime64" => CrystalClick::BinaryValue.fixed(zoned_types["datetime64"], raw64),
    })

    display_name_delta =
      (zoned_types["datetime"].name.bytesize - bare_types["datetime"].name.bytesize).to_u64 +
        (zoned_types["datetime64"].name.bytesize - bare_types["datetime64"].name.bytesize).to_u64
    zone_delta = CrystalClick::TimezoneName.parse("UTC").not_nil!.logical_charge +
                 CrystalClick::TimezoneName.parse("Etc/UTC").not_nil!.logical_charge
    (w139_document_budget_charge(zoned_document) - w139_document_budget_charge(bare_document)).should eq(
      display_name_delta + zone_delta
    )

    exact_charge = w139_document_budget_charge(zoned_document)
    exact = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: exact_charge)
    exact.reserve_base(0_u64, 0_u64)
    exact.charge_document(zoned_document)
    exact.retained_logical_bytes.should eq(exact_charge)

    one_short = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: exact_charge - 1_u64)
    one_short.reserve_base(0_u64, 0_u64)
    expect_raises(CrystalClick::BoundsError) { one_short.charge_document(zoned_document) }
    one_short.retained_logical_bytes.should eq(instance_sizeof(Array(CrystalClick::OfflineColumnValue)).to_u64)
  end

  it "revalidates borrowed temporal preflights, exact zone spans, and nonzero-offset slice bounds" do
    token = "DateTime64(3, 'UTC')"
    bytes = Bytes.new(token.bytesize + 2)
    bytes[0] = '!'.ord.to_u8
    token.to_slice.each_with_index { |byte, index| bytes[index + 1] = byte }
    bytes[bytes.size - 1] = '?'.ord.to_u8
    first = 1
    after = first + token.bytesize

    resolution = CrystalClick::ObjectTypedFieldType.resolve_slice(bytes, first, after).not_nil!
    resolution.explicit_zone_bytes.should eq(3_u64)
    resolution.materialize.should eq(CrystalClick::BinaryDataType.datetime64(3, "UTC"))

    truncated = CrystalClick::ObjectTemporalDeclaration.resolve_slice(bytes, first, after - 1)
    truncated.should be_nil
    CrystalClick::TimezoneName.admitted_slice?(bytes, first + 15, first + 18).should be_true
    CrystalClick::TimezoneName.admitted_slice?(bytes, first + 15, bytes.size + 1).should be_false

    zone_first = first + "DateTime64(".bytesize + 1 + ", '".bytesize
    wrong_span = CrystalClick::ObjectTemporalDeclaration::Preflight.new(
      bytes,
      first,
      after,
      CrystalClick::BinaryDataType::TAG_DATETIME64_ZONE,
      3,
      zone_first + 1,
      zone_first + 4,
    )
    expect_raises(ArgumentError) { wrong_span.materialize }

    temporal = CrystalClick::ObjectTemporalDeclaration.resolve_slice(bytes, first, after).not_nil!
    forged_resolution = CrystalClick::ObjectTypedFieldType::Resolution.new(
      CrystalClick::BinaryDataType::TAG_DATETIME64_ZONE,
      0,
      token.bytesize,
      3,
      temporal_preflight: temporal,
      explicit_zone_bytes: 2_u64,
    )
    expect_raises(ArgumentError) { forged_resolution.materialize }
    forged_scale_resolution = CrystalClick::ObjectTypedFieldType::Resolution.new(
      CrystalClick::BinaryDataType::TAG_DATETIME64_ZONE,
      0,
      token.bytesize,
      4,
      temporal_preflight: temporal,
      explicit_zone_bytes: 3_u64,
    )
    expect_raises(ArgumentError) { forged_scale_resolution.materialize }
    forged_tag_resolution = CrystalClick::ObjectTypedFieldType::Resolution.new(
      CrystalClick::BinaryDataType::TAG_DATETIME64,
      0,
      token.bytesize,
      3,
      temporal_preflight: temporal,
      explicit_zone_bytes: 3_u64,
    )
    expect_raises(ArgumentError) { forged_tag_resolution.materialize }

    changed_zone = Bytes.new(token.bytesize) { |index| token.to_slice[index] }
    changed_preflight = CrystalClick::ObjectTemporalDeclaration.resolve_slice(changed_zone, 0, changed_zone.size).not_nil!
    changed_zone["DateTime64(3, 'UT".bytesize] = '!'.ord.to_u8
    expect_raises(ArgumentError) { changed_preflight.materialize }

    changed_scale = Bytes.new(token.bytesize) { |index| token.to_slice[index] }
    scale_preflight = CrystalClick::ObjectTemporalDeclaration.resolve_slice(changed_scale, 0, changed_scale.size).not_nil!
    changed_scale["DateTime64(".bytesize] = '4'.ord.to_u8
    expect_raises(ArgumentError) { scale_preflight.materialize }

    same_size_zone = Bytes.new(token.bytesize) { |index| token.to_slice[index] }
    zone_preflight = CrystalClick::ObjectTemporalDeclaration.resolve_slice(same_size_zone, 0, same_size_zone.size).not_nil!
    "GMT".to_slice.each_with_index do |byte, index|
      same_size_zone["DateTime64(3, '".bytesize + index] = byte
    end
    zone_preflight.materialize.name.should eq("DateTime64(3, 'GMT')")
  end

  it "keeps owned timezone identity private from an IO that mutates offered byte slices" do
    probe = Bytes.new(W139MutatingIO::TARGET_ZONE.bytesize) do |index|
      W139MutatingIO::TARGET_ZONE.to_slice[index]
    end
    mutator = W139MutatingIO.new
    mutator.write(probe)
    probe[0].should eq('X'.ord.to_u8)

    zone = CrystalClick::TimezoneName.parse(W139MutatingIO::TARGET_ZONE).not_nil!
    zone_io = W139MutatingIO.new
    zone.append_name(zone_io)
    zone_io.rendered.should eq(W139MutatingIO::TARGET_ZONE)
    zone.name.should eq(W139MutatingIO::TARGET_ZONE)

    type = CrystalClick::BinaryDataType.datetime64(3, W139MutatingIO::TARGET_ZONE)
    type_io = W139MutatingIO.new
    CrystalClick::ObjectTemporalDeclaration.append_name(type_io, type)
    expected = "DateTime64(3, '#{W139MutatingIO::TARGET_ZONE}')"
    type_io.rendered.should eq(expected)
    type.name.should eq(expected)
  end
end
