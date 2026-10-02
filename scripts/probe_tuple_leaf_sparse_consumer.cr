require "../src/crystal_click"

# A test-only seam fixes the argument's static type to the failing consumer
# specialization. Merely calling public constructors in one broad graph is
# insufficient to expose this compile-time cast defect.
class CrystalClick::WideTupleLeafColumn
  def infer_uint64_for_sparse_consumer(values : Array(UInt64)) : CrystalClick::WideTupleLeafType
    inferred_leaf_type(values)
  end
end

# Compile this consumer separately: adding other carrier constructors to the
# full spec graph can hide an invalid cast in a closed Buffer union.
def check_sparse_leaf(
  name : String,
  expected_type : String,
  source : Array(UInt64) | Array(String),
) : Nil
  expected = source.dup
  column = CrystalClick::WideTupleLeafColumn.new(name, source)
  raise "wrong sparse-consumer declaration" unless column.type_name == expected_type
  raise "wrong sparse-consumer values" unless column.physical_values == expected

  source.clear
  raise "constructor retained the caller's array" unless column.physical_values == expected
  detached = column.physical_values
  detached.clear
  raise "physical_values leaked the owned array" unless column.physical_values == expected

  copied = column.owned_copy
  raise "owned_copy changed the declaration" unless copied.type_name == expected_type
  raise "owned_copy changed values" unless copied.physical_values == expected
  raise "owned_copy changed row count" unless copied.size == expected.size
end

check_sparse_leaf("numbers", "UInt64", [0_u64, UInt64::MAX])
check_sparse_leaf("empty_numbers", "UInt64", [] of UInt64)
check_sparse_leaf("strings", "String", ["", "a\0b", "é", String.new(Bytes[0xff_u8])])
check_sparse_leaf("empty_strings", "String", [] of String)

# A generic numeric constructor must also compile without any identifier
# constructor elsewhere in this consumer graph.
signed = CrystalClick::WideTupleLeafColumn.new("signed", [Int64::MIN, Int64::MAX])
raise "generic numeric declaration changed" unless signed.type_name == "Int64"
raise "generic numeric values changed" unless signed.values_as(Int64) == [Int64::MIN, Int64::MAX]
numeric = CrystalClick::WideTupleLeafColumn.new("numeric", [0_u64])
raise "UInt64 inference changed" unless numeric.infer_uint64_for_sparse_consumer([UInt64::MAX]).type_name == "UInt64"
puts "PASS isolated numeric/String Tuple leaf consumer"
