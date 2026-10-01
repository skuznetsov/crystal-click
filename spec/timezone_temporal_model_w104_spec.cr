require "./spec_helper"

private def w104_timezone_fixture_names : Array(String)
  File.read(File.expand_path("fixtures/stock_timezone_names_26_7.txt", __DIR__))
    .split('\n')
    .reject(&.empty?)
end

private def w104_fixed_offset_names : Array(String)
  names = [] of String
  offset_minutes = -840
  while offset_minutes <= 840
    absolute_minutes = offset_minutes.abs
    hours = absolute_minutes // 60
    minutes = absolute_minutes % 60
    sign = offset_minutes < 0 ? "-" : "+"
    hour_text = hours < 10 ? "0#{hours}" : hours.to_s
    minute_text = minutes < 10 ? "0#{minutes}" : minutes.to_s
    names << "Fixed/UTC#{sign}#{hour_text}:#{minute_text}:00"
    offset_minutes += 15
  end
  # The canonical quarter-hour sequence has one zero spelling. ClickHouse
  # additionally admits the negative-zero name as a distinct exact token.
  names << "Fixed/UTC-00:00:00"
  names
end

private def w104_descriptor_shapes : Array(Tuple(CrystalClick::DateTimeColumnType::Shape, Int32, Bool))
  [
    {CrystalClick::DateTimeColumnType::Shape::Scalar, 0, false},
    {CrystalClick::DateTimeColumnType::Shape::Nullable, 0, true},
    {CrystalClick::DateTimeColumnType::Shape::Array, 1, false},
    {CrystalClick::DateTimeColumnType::Shape::ArrayNullable, 1, true},
    {CrystalClick::DateTimeColumnType::Shape::ArrayArray, 2, false},
    {CrystalClick::DateTimeColumnType::Shape::ArrayArrayNullable, 2, true},
  ]
end

private def w104_type_with_shape(
  leaf_type : String,
  shape : CrystalClick::DateTimeColumnType::Shape,
) : String
  case shape
  when CrystalClick::DateTimeColumnType::Shape::Scalar
    leaf_type
  when CrystalClick::DateTimeColumnType::Shape::Nullable
    "Nullable(#{leaf_type})"
  when CrystalClick::DateTimeColumnType::Shape::Array
    "Array(#{leaf_type})"
  when CrystalClick::DateTimeColumnType::Shape::ArrayNullable
    "Array(Nullable(#{leaf_type}))"
  when CrystalClick::DateTimeColumnType::Shape::ArrayArray
    "Array(Array(#{leaf_type}))"
  when CrystalClick::DateTimeColumnType::Shape::ArrayArrayNullable
    "Array(Array(Nullable(#{leaf_type})))"
  else
    raise "unhandled W104 temporal descriptor shape #{shape}"
  end
end

private def w104_mutate_first_byte(value : String, byte : UInt8) : Nil
  raise "W104 ownership fixture must be non-empty" if value.empty?
  value.to_unsafe[0] = byte
end

describe CrystalClick::TimezoneName do
  it "admits every exact name in the pinned measured stock catalog" do
    names = w104_timezone_fixture_names
    names.size.should eq(597)
    names.uniq.size.should eq(597)
    names.sort.should eq(names)
    names.map(&.bytesize).max.should eq(32)

    names.each do |name|
      owner = CrystalClick::TimezoneName.parse(name)
      owner.should_not be_nil
      if owner
        owner.name.should eq(name)
      end
    end
  end

  it "admits exactly the canonical 114 fixed quarter-hour offset names" do
    names = w104_fixed_offset_names
    names.size.should eq(114)
    names.uniq.size.should eq(114)

    names.each do |name|
      owner = CrystalClick::TimezoneName.parse(name)
      owner.should_not be_nil
      if owner
        owner.name.should eq(name)
      end
    end

    positive_zero = CrystalClick::TimezoneName.parse("Fixed/UTC+00:00:00")
    negative_zero = CrystalClick::TimezoneName.parse("Fixed/UTC-00:00:00")
    positive_zero.should_not be_nil
    negative_zero.should_not be_nil
    if positive_zero && negative_zero
      positive_zero.should_not eq(negative_zero)
      positive_zero.name.should eq("Fixed/UTC+00:00:00")
      negative_zero.name.should eq("Fixed/UTC-00:00:00")
    end

    [
      "Fixed/UTC+14:15:00",
      "Fixed/UTC-14:15:00",
      "Fixed/UTC+05:46:00",
      "Fixed/UTC+05:45:15",
      "Fixed/UTC+05:45",
      "Fixed/UTC+5:45:00",
      "Fixed/UTC+0545",
    ].each do |name|
      CrystalClick::TimezoneName.parse(name).should be_nil
    end
  end

  it "preserves aliases as separate exact names instead of resolving them" do
    [
      {"UTC", "Etc/UTC"},
      {"UTC", "Universal"},
      {"America/New_York", "US/Eastern"},
      {"EST5EDT", "America/New_York"},
      {"GMT0", "UTC"},
    ].each do |left_name, right_name|
      left = CrystalClick::TimezoneName.parse(left_name)
      right = CrystalClick::TimezoneName.parse(right_name)
      left.should_not be_nil
      right.should_not be_nil
      if left && right
        left.name.should eq(left_name)
        right.name.should eq(right_name)
        left.should_not eq(right)
      end
    end
  end

  it "owns its input and every exposed name string" do
    source = String.new("America/New_York".to_slice)
    owner = CrystalClick::TimezoneName.parse(source)
    owner.should_not be_nil
    if owner
      w104_mutate_first_byte(source, 'X'.ord.to_u8)
      owner.name.should eq("America/New_York")

      exposed = owner.name
      w104_mutate_first_byte(exposed, 'Y'.ord.to_u8)
      owner.name.should eq("America/New_York")
      owner.should eq(CrystalClick::TimezoneName.parse("America/New_York"))
    end
  end

  it "keeps direct construction behind the same pinned-name admission gate" do
    expect_raises(ArgumentError) { CrystalClick::TimezoneName.new("Definitely/Not_A_Zone") }
  end

  it "rejects unknown, unsafe, host-path, libc-expression, NUL, and quoted names" do
    names = w104_timezone_fixture_names
    rejected = [
      "",
      "Definitely/Not_A_Zone",
      "/etc/localtime",
      "/usr/share/zoneinfo/America/New_York",
      "zoneinfo/America/New_York",
      "../UTC",
      "America/../UTC",
      "America//New_York",
      "localtime",
      "posixrules",
      "right/UTC",
      "posix/UTC",
      ":America/New_York",
      "UTC0",
      "UTC ",
      " UTC",
      "'UTC'",
    ]
    nul = String.new(Bytes[0_u8])
    rejected << "UTC#{nul}"

    rejected.each do |name|
      names.includes?(name).should be_false
      CrystalClick::TimezoneName.parse(name).should be_nil
    end
  end
end

describe CrystalClick::DateTimeColumnType do
  it "round-trips both families across every precision, timezone, and descriptor shape" do
    w104_descriptor_shapes.each do |shape, expected_depth, expected_nullable|
      ["UTC", "America/New_York"].each do |zone|
        datetime = CrystalClick::DateTimeColumnType.datetime(time_zone: zone).with_shape(shape)
        datetime_leaf = "DateTime('#{zone}')"
        datetime_name = w104_type_with_shape(datetime_leaf, shape)

        datetime.family.should eq(CrystalClick::DateTimeColumnType::Family::DateTime)
        datetime.precision?.should be_nil
        datetime.time_zone?.try(&.name).should eq(zone)
        datetime.shape.should eq(shape)
        datetime.array_depth.should eq(expected_depth)
        datetime.nullable_leaf?.should eq(expected_nullable)
        datetime.raw_width.should eq(4)
        datetime.leaf_type_name.should eq(datetime_leaf)
        datetime.type_name.should eq(datetime_name)
        parsed_datetime = CrystalClick::DateTimeColumnType.parse(datetime_name)
        parsed_datetime.should_not be_nil
        if parsed_datetime
          parsed_datetime.should eq(datetime)
          parsed_datetime.hash.should eq(datetime.hash)
        end
        parsed_leaf = CrystalClick::DateTimeColumnType.parse_leaf(datetime_leaf)
        parsed_leaf.should_not be_nil
        if parsed_leaf
          parsed_leaf.shape.should eq(CrystalClick::DateTimeColumnType::Shape::Scalar)
          parsed_leaf.leaf_type_name.should eq(datetime_leaf)
          parsed_leaf.time_zone?.try(&.name).should eq(zone)
        end

        (0..9).each do |scale|
          datetime64 = CrystalClick::DateTimeColumnType.datetime64(scale, time_zone: zone).with_shape(shape)
          datetime64_leaf = "DateTime64(#{scale}, '#{zone}')"
          datetime64_name = w104_type_with_shape(datetime64_leaf, shape)

          datetime64.family.should eq(CrystalClick::DateTimeColumnType::Family::DateTime64)
          datetime64.precision?.should eq(scale.to_u8)
          datetime64.time_zone?.try(&.name).should eq(zone)
          datetime64.shape.should eq(shape)
          datetime64.array_depth.should eq(expected_depth)
          datetime64.nullable_leaf?.should eq(expected_nullable)
          datetime64.raw_width.should eq(8)
          datetime64.leaf_type_name.should eq(datetime64_leaf)
          datetime64.type_name.should eq(datetime64_name)
          parsed_datetime64 = CrystalClick::DateTimeColumnType.parse(datetime64_name)
          parsed_datetime64.should_not be_nil
          if parsed_datetime64
            parsed_datetime64.should eq(datetime64)
            parsed_datetime64.hash.should eq(datetime64.hash)
          end
          parsed_datetime64_leaf = CrystalClick::DateTimeColumnType.parse_leaf(datetime64_leaf)
          parsed_datetime64_leaf.should_not be_nil
          if parsed_datetime64_leaf
            parsed_datetime64_leaf.shape.should eq(CrystalClick::DateTimeColumnType::Shape::Scalar)
            parsed_datetime64_leaf.precision?.should eq(scale.to_u8)
            parsed_datetime64_leaf.leaf_type_name.should eq(datetime64_leaf)
          end
        end
      end
    end
  end

  it "preserves bare legacy types and rejects invalid builder inputs" do
    datetime = CrystalClick::DateTimeColumnType.datetime
    datetime.family.should eq(CrystalClick::DateTimeColumnType::Family::DateTime)
    datetime.shape.should eq(CrystalClick::DateTimeColumnType::Shape::Scalar)
    datetime.precision?.should be_nil
    datetime.time_zone?.should be_nil
    datetime.leaf_type_name.should eq("DateTime")
    datetime.type_name.should eq("DateTime")
    exposed_bare_leaf = datetime.leaf_type_name
    w104_mutate_first_byte(exposed_bare_leaf, 'X'.ord.to_u8)
    datetime.leaf_type_name.should eq("DateTime")

    (0..9).each do |scale|
      datetime64 = CrystalClick::DateTimeColumnType.datetime64(scale)
      datetime64.type_name.should eq("DateTime64(#{scale})")
      datetime64.precision?.should eq(scale.to_u8)
      datetime64.time_zone?.should be_nil
      parsed = CrystalClick::DateTimeColumnType.parse(datetime64.type_name)
      parsed.should_not be_nil
      if parsed
        parsed.should eq(datetime64)
      end
    end

    expect_raises(ArgumentError) { CrystalClick::DateTimeColumnType.datetime(time_zone: "") }
    expect_raises(ArgumentError) { CrystalClick::DateTimeColumnType.datetime(time_zone: "Definitely/Not_A_Zone") }
    expect_raises(ArgumentError) { CrystalClick::DateTimeColumnType.datetime64(-1) }
    expect_raises(ArgumentError) { CrystalClick::DateTimeColumnType.datetime64(10) }
    expect_raises(ArgumentError) { CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "localtime") }

    expect_raises(ArgumentError) do
      CrystalClick::DateTimeColumnType.new(
        CrystalClick::DateTimeColumnType::Family::DateTime,
        3_u8,
        nil,
        CrystalClick::DateTimeColumnType::Shape::Scalar
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::DateTimeColumnType.new(
        CrystalClick::DateTimeColumnType::Family::DateTime64,
        nil,
        nil,
        CrystalClick::DateTimeColumnType::Shape::Scalar
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::DateTimeColumnType.new(
        CrystalClick::DateTimeColumnType::Family::DateTime64,
        10_u8,
        nil,
        CrystalClick::DateTimeColumnType::Shape::Scalar
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::DateTimeColumnType.new(
        CrystalClick::DateTimeColumnType::Family.new(255),
        nil,
        nil,
        CrystalClick::DateTimeColumnType::Shape::Scalar
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::DateTimeColumnType.new(
        CrystalClick::DateTimeColumnType::Family::DateTime,
        nil,
        nil,
        CrystalClick::DateTimeColumnType::Shape.new(255)
      )
    end
  end

  it "keeps exact schema identity separate from unchanged raw timestamp equality" do
    utc_datetime = CrystalClick::DateTimeColumnType.datetime(time_zone: "UTC")
    etc_datetime = CrystalClick::DateTimeColumnType.datetime(time_zone: "Etc/UTC")
    utc_datetime.should_not eq(etc_datetime)
    utc_datetime.type_name.should eq("DateTime('UTC')")
    etc_datetime.type_name.should eq("DateTime('Etc/UTC')")
    parsed_utc = CrystalClick::DateTimeColumnType.parse("DateTime('UTC')")
    parsed_utc.should_not be_nil
    if parsed_utc
      utc_datetime.should eq(parsed_utc)
      utc_datetime.hash.should eq(parsed_utc.hash)
    end
    CrystalClick::DateTimeValue.new(1_723_456_789_u32).should eq(CrystalClick::DateTimeValue.new(1_723_456_789_u32))

    utc_ticks = CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "UTC")
    alias_ticks = CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "Universal")
    precision_ticks = CrystalClick::DateTimeColumnType.datetime64(4, time_zone: "UTC")
    utc_ticks.should_not eq(alias_ticks)
    utc_ticks.should_not eq(precision_ticks)
    CrystalClick::DateTime64Value.new(-1_723_456_789_i64, 3).should eq(
      CrystalClick::DateTime64Value.new(-1_723_456_789_i64, 3)
    )
    CrystalClick::DateTime64Value.new(-1_723_456_789_i64, 3).should_not eq(
      CrystalClick::DateTime64Value.new(-1_723_456_789_i64, 4)
    )

    positive_zero = CrystalClick::DateTimeColumnType.datetime(time_zone: "Fixed/UTC+00:00:00")
    negative_zero = CrystalClick::DateTimeColumnType.datetime(time_zone: "Fixed/UTC-00:00:00")
    positive_zero.should_not eq(negative_zero)
    positive_zero.type_name.should eq("DateTime('Fixed/UTC+00:00:00')")
    negative_zero.type_name.should eq("DateTime('Fixed/UTC-00:00:00')")
    CrystalClick::DateTimeValue.new(0_u32).should eq(CrystalClick::DateTimeValue.new(0_u32))

    positive_zero64 = CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "Fixed/UTC+00:00:00")
    negative_zero64 = CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "Fixed/UTC-00:00:00")
    positive_zero64.should_not eq(negative_zero64)
    positive_zero64.type_name.should eq("DateTime64(3, 'Fixed/UTC+00:00:00')")
    negative_zero64.type_name.should eq("DateTime64(3, 'Fixed/UTC-00:00:00')")
    CrystalClick::DateTime64Value.new(0_i64, 3).should eq(CrystalClick::DateTime64Value.new(0_i64, 3))
  end

  it "copies source and exposed zone and canonical-name strings" do
    source_zone = String.new("America/New_York".to_slice)
    datetime = CrystalClick::DateTimeColumnType.datetime(time_zone: source_zone)
    w104_mutate_first_byte(source_zone, 'X'.ord.to_u8)
    datetime.time_zone?.try(&.name).should eq("America/New_York")

    exposed_zone_owner = datetime.time_zone?
    exposed_zone_owner.should_not be_nil
    exposed_zone = exposed_zone_owner.try(&.name)
    exposed_zone.should_not be_nil
    exposed_leaf = datetime.leaf_type_name
    exposed_type = datetime.type_name
    if exposed_zone
      w104_mutate_first_byte(exposed_zone, 'Y'.ord.to_u8)
    end
    w104_mutate_first_byte(exposed_leaf, 'Z'.ord.to_u8)
    w104_mutate_first_byte(exposed_type, 'X'.ord.to_u8)
    datetime.time_zone?.try(&.name).should eq("America/New_York")
    datetime.leaf_type_name.should eq("DateTime('America/New_York')")
    datetime.type_name.should eq("DateTime('America/New_York')")

    parse_source = String.new("DateTime64(3, 'US/Eastern')".to_slice)
    parsed = CrystalClick::DateTimeColumnType.parse(parse_source)
    parsed.should_not be_nil
    if parsed
      w104_mutate_first_byte(parse_source, 'X'.ord.to_u8)
      parsed.type_name.should eq("DateTime64(3, 'US/Eastern')")
      parsed.time_zone?.try(&.name).should eq("US/Eastern")
    end
  end

  it "rejects noncanonical, escaped, unsafe, and out-of-profile type spellings" do
    slash = String.new(Bytes[0x5c_u8])
    nul = String.new(Bytes[0_u8])
    rejected = [
      "DateTime()",
      "DateTime(UTC)",
      "DateTime('')",
      "DateTime( 'UTC')",
      "DateTime('UTC' )",
      "DateTime ('UTC')",
      "DateTime(\"UTC\")",
      "DateTime('UTC)",
      "DateTime('America'New_York')",
      "DateTime('UTC') trailing",
      "DateTime('Definitely/Not_A_Zone')",
      "DateTime('/etc/localtime')",
      "DateTime('localtime')",
      "DateTime('posixrules')",
      "DateTime(':America/New_York')",
      "DateTime('UTC#{slash}x00')",
      "DateTime('America#{slash}New_York')",
      "DateTime('UTC#{nul}')",
      "DateTime64(03, 'UTC')",
      "DateTime64(10, 'UTC')",
      "DateTime64(-1, 'UTC')",
      "DateTime64(3, UTC)",
      "DateTime64(3,'UTC')",
      "DateTime64(3, 'UTC' )",
      "DateTime64( 3, 'UTC')",
      "DateTime64(3, 'UTC') trailing",
      "Nullable(Array(DateTime('UTC'))) ",
      "Array(Array(Array(DateTime('UTC'))))",
      "Array(Nullable(Nullable(DateTime('UTC'))))",
      "Tuple(event DateTime('UTC'))",
    ]

    rejected.each do |type_name|
      CrystalClick::DateTimeColumnType.parse(type_name).should be_nil
    end

    CrystalClick::DateTimeColumnType.parse_leaf("Nullable(DateTime('UTC'))").should be_nil
    CrystalClick::DateTimeColumnType.parse_leaf("DateTime('UTC') trailing").should be_nil
  end

  it "retains temporal descriptors through named Tuple fields, plan copies, rows, and empty columns" do
    leaf_type = "DateTime64(3, 'US/Eastern')"
    tuple_source = String.new("Tuple(occurred #{leaf_type})".to_slice)
    tuple_type = "Tuple(occurred #{leaf_type})"
    plan = CrystalClick::WideTupleTypePlan.for_type(tuple_source)
    plan.should_not be_nil
    if plan
      w104_mutate_first_byte(tuple_source, 'X'.ord.to_u8)
      plan.type_name.should eq(tuple_type)
      returned_fields = plan.fields
      returned_fields.map { |field| {field.name, field.type_name} }.should eq([{"occurred", leaf_type}])

      first_field = returned_fields.first
      field_descriptor = first_field.datetime_type
      field_descriptor.should_not be_nil
      if field_descriptor
        field_descriptor.family.should eq(CrystalClick::DateTimeColumnType::Family::DateTime64)
        field_descriptor.precision?.should eq(3_u8)
        field_descriptor.time_zone?.try(&.name).should eq("US/Eastern")
        field_descriptor.shape.should eq(CrystalClick::DateTimeColumnType::Shape::Scalar)
      end
      returned_fields.clear
      plan.fields.first.datetime_type.should eq(field_descriptor)

      values = [CrystalClick::DateTime64Value.new(-987_654_321_i64, 3)]
      column = CrystalClick::WideTupleLeafColumn.new("occurred", leaf_type, values)
      data = CrystalClick::WideTupleColumnData.new(plan, [column])
      row = data.row(0)
      row.type_name.should eq(tuple_type)
      row.fields.map { |field| {field.name, field.type_name} }.should eq([{"occurred", leaf_type}])
      row_descriptor = row.fields.first.datetime_type
      row_descriptor.should_not be_nil
      if row_descriptor
        row_descriptor.should eq(field_descriptor)
        row_descriptor.time_zone?.try(&.name).should eq("US/Eastern")
      end
      row.value_as("occurred", CrystalClick::DateTime64Value).should eq(
        CrystalClick::DateTime64Value.new(-987_654_321_i64, 3)
      )

      copied_column = data.columns.first
      copied_column.type_name.should eq(leaf_type)
      copied_column.owned_copy.type_name.should eq(leaf_type)
      exposed_field_type = row.fields.first.type_name
      w104_mutate_first_byte(exposed_field_type, 'X'.ord.to_u8)
      row.type_name.should eq(tuple_type)
      row.fields.first.type_name.should eq(leaf_type)

      empty_column = CrystalClick::WideTupleLeafColumn.new(
        "occurred", leaf_type, [] of CrystalClick::DateTime64Value
      )
      empty_data = CrystalClick::WideTupleColumnData.new(plan, [empty_column])
      empty_data.row_count.should eq(0)
      empty_data.type_name.should eq(tuple_type)
      empty_data.fields.first.type_name.should eq(leaf_type)
      empty_descriptor = empty_data.fields.first.datetime_type
      empty_descriptor.should_not be_nil
      if empty_descriptor
        empty_descriptor.should eq(field_descriptor)
        empty_descriptor.time_zone?.try(&.name).should eq("US/Eastern")
      end
      empty_data.columns.first.type_name.should eq(leaf_type)
      empty_data.columns.first.owned_copy.type_name.should eq(leaf_type)
    end
  end

  it "charges each retained temporal descriptor and its actual row wrapper slot" do
    tuple_type = "Tuple(a DateTime, b DateTime64(3), c DateTime('UTC'), d DateTime64(3, 'America/New_York'))"
    plan = CrystalClick::WideTupleTypePlan.for_type(tuple_type)
    plan.should_not be_nil
    if plan
      fields = plan.fields
      fields.size.should eq(4)
      descriptor_charge = 0_u64
      leaf_owner_charge = 0_u64
      fields.each do |field|
        descriptor = field.datetime_type
        descriptor.should_not be_nil
        if descriptor
          descriptor.logical_charge.should be > 0_u64
          descriptor_charge += descriptor.logical_charge
        end
        base_type_name = field.leaf_type.base_type_name
        leaf_owner_charge += instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
                             instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
      end

      bare_datetime = CrystalClick::DateTimeColumnType.datetime
      zoned_datetime = CrystalClick::DateTimeColumnType.datetime(time_zone: "UTC")
      bare_datetime.logical_charge.should eq(instance_sizeof(CrystalClick::DateTimeColumnType).to_u64)
      utc_zone = zoned_datetime.time_zone?.not_nil!
      utc_zone.logical_charge.should eq(
        instance_sizeof(CrystalClick::TimezoneName).to_u64 +
        instance_sizeof(String).to_u64 + "UTC".bytesize.to_u64 + 1_u64
      )
      zoned_datetime.logical_charge.should eq(
        instance_sizeof(CrystalClick::DateTimeColumnType).to_u64 + utc_zone.logical_charge
      )
      bare_datetime64 = CrystalClick::DateTimeColumnType.datetime64(3)
      zoned_datetime64 = CrystalClick::DateTimeColumnType.datetime64(3, time_zone: "UTC")
      bare_datetime64.logical_charge.should eq(instance_sizeof(CrystalClick::DateTimeColumnType).to_u64)
      zoned_datetime64.logical_charge.should eq(
        instance_sizeof(CrystalClick::DateTimeColumnType).to_u64 + utc_zone.logical_charge
      )

      # Each copied field slot is billed at its actual inline representation;
      # the separately retained temporal descriptor is charged once per field.
      field_slot_charge = sizeof(CrystalClick::WideTupleField).to_u64
      CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES.should eq(field_slot_charge)
      base_charge = 64_u64 + 4_u64 * field_slot_charge + leaf_owner_charge + descriptor_charge
      plan.materialization_charge(0_u64, 0_u64).should eq(base_charge)
      plan.materialization_charge(0_u64, 17_u64).should eq(base_charge + 17_u64)

      one_row_charge = plan.materialization_charge(1_u64, 0_u64)
      one_row_charge.should_not be_nil
      if one_row_charge
        expected_slots = 8_u64 + 2_u64 * sizeof(CrystalClick::DateTimeValue).to_u64 +
                         2_u64 * sizeof(CrystalClick::DateTime64Value).to_u64
        one_row_charge.should eq(base_charge + expected_slots)
      end

      plan.materialization_charge(UInt64::MAX, 0_u64).should be_nil
      plan.materialization_charge(0_u64, UInt64::MAX).should be_nil
    end
  end
end

describe CrystalClick::WideTupleTypePlan do
  it "counts a timezone parameter against the existing Tuple syntax-node limit" do
    alphabet = [] of String
    ('a'.ord..'z'.ord).each { |codepoint| alphabet << codepoint.chr.to_s }

    names = [] of String
    alphabet.each { |character| names << character }
    first = 'a'.ord
    while first <= 'z'.ord && names.size < 511
      second = 'a'.ord
      while second <= 'z'.ord && names.size < 511
        names << "#{first.chr}#{second.chr}"
        second += 1
      end
      first += 1
    end
    names.size.should eq(511)
    names.uniq.size.should eq(511)

    bare_source = "Tuple(#{names.map { |name| "#{name} Bool" }.join(",")})"
    zoned_fields = names.map { |name| "#{name} Bool" }
    zoned_fields[-1] = "#{names.last} DateTime('UTC')"
    zoned_source = "Tuple(#{zoned_fields.join(",")})"

    # 1 Tuple node + 511 field nodes is exactly the 512-node limit. Replacing
    # one Bool with DateTime('UTC') adds the timezone argument as node 513.
    bare_source.bytesize.should eq(4_068)
    zoned_source.bytesize.should eq(4_079)
    bare_source.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    zoned_source.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    bare_plan = CrystalClick::WideTupleTypePlan.for_type(bare_source)
    bare_plan.should_not be_nil
    if bare_plan
      bare_plan.fields.size.should eq(511)
    end
    CrystalClick::WideTupleTypePlan.for_type(zoned_source).should be_nil
  end
end
