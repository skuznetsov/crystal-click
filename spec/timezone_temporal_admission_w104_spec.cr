require "./spec_helper"

private def w104_temporal_shapes : Array(String)
  ["scalar", "nullable", "array", "array_nullable", "nested", "nested_nullable", "tuple"]
end

private def w104_temporal_type(shape : String, leaf : String) : String
  case shape
  when "scalar"          then leaf
  when "nullable"        then "Nullable(#{leaf})"
  when "array"           then "Array(#{leaf})"
  when "array_nullable"  then "Array(Nullable(#{leaf}))"
  when "nested"          then "Array(Array(#{leaf}))"
  when "nested_nullable" then "Array(Array(Nullable(#{leaf})))"
  when "tuple"           then "Tuple(event #{leaf})"
  else
    raise "unknown W104 temporal shape #{shape}"
  end
end

private def w104_bare_temporal_leaves : Array(String)
  leaves = ["DateTime"]
  (0..9).each do |precision|
    leaves << "DateTime64(#{precision})"
  end
  leaves
end

private def w104_zoned_temporal_leaves : Array(Tuple(String, String))
  leaves = [] of Tuple(String, String)
  ["UTC", "America/New_York"].each do |zone|
    leaves << {zone, "DateTime('#{zone}')"}
    (0..9).each do |precision|
      leaves << {zone, "DateTime64(#{precision}, '#{zone}')"}
    end
  end
  leaves
end

describe "W104 timezone-qualified DateTime type admission" do
  w104_temporal_shapes.each do |shape|
    w104_bare_temporal_leaves.each do |leaf|
      type_name = w104_temporal_type(shape, leaf)

      it "retains bare #{type_name} as a positive control" do
        CrystalClick::WidePart.supports_typed_type?(type_name).should be_true

        if shape == "tuple"
          plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
          plan.should_not be_nil
          if plan
            plan.type_name.should eq(type_name)
            plan.fields.first.type_name.should eq(leaf)
          end
        end
      end
    end
  end

  w104_temporal_shapes.each do |shape|
    w104_zoned_temporal_leaves.each do |zone, leaf|
      type_name = w104_temporal_type(shape, leaf)

      it "admits #{type_name} without losing its declared timezone" do
        CrystalClick::WidePart.supports_typed_type?(type_name).should be_true

        if shape == "tuple"
          plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
          plan.should_not be_nil
          if plan
            plan.type_name.should eq(type_name)
            plan.fields.first.type_name.should eq(leaf)
          end
        end
      end
    end
  end

  ["UTC", "Etc/UTC"].each do |zone|
    leaf = "DateTime('#{zone}')"
    type_name = "Tuple(event #{leaf})"

    it "retains #{zone} as an exact name in named Tuple metadata" do
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_true
      plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
      plan.should_not be_nil
      if plan
        plan.type_name.should eq(type_name)
        plan.fields.first.type_name.should eq(leaf)
      end
    end
  end

  it "rejects malformed zone literals, precision spellings, and shapes outside the existing profile" do
    malformed_leaves = [
      "DateTime('')",
      "DateTime(UTC)",
      "DateTime('Definitely/Not_A_Zone')",
      "DateTime('/etc/localtime')",
      "DateTime64(03, 'UTC')",
      "DateTime64(10, 'UTC')",
      "DateTime64(-1, 'UTC')",
      "DateTime64(3, UTC)",
      "DateTime64(3, 'Definitely/Not_A_Zone')",
    ]

    malformed_leaves.each do |leaf|
      CrystalClick::WidePart.supports_typed_type?(leaf).should be_false
      CrystalClick::WideTupleTypePlan.for_type("Tuple(event #{leaf})").should be_nil
    end

    [
      "Nullable(Array(DateTime('UTC')))",
      "Array(Array(Array(DateTime('UTC'))))",
      "Array(Nullable(Nullable(DateTime('UTC'))))",
      "Tuple(event Nullable(Array(DateTime('UTC'))))",
      "Tuple(event DateTime64(03, 'UTC'))",
    ].each do |type_name|
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_false
      if type_name.starts_with?("Tuple(")
        CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
      end
    end
  end
end
