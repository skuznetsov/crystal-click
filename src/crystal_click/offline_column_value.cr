module CrystalClick
  alias OfflineArrayMapUInt64NumericValue = Array(Array(Tuple(UInt64, UInt8))) | Array(Array(Tuple(UInt64, UInt16))) |
                                            Array(Array(Tuple(UInt64, UInt32))) | Array(Array(Tuple(UInt64, UInt64))) |
                                            Array(Array(Tuple(UInt64, Int8))) | Array(Array(Tuple(UInt64, Int16))) |
                                            Array(Array(Tuple(UInt64, Int32))) | Array(Array(Tuple(UInt64, Int64))) |
                                            Array(Array(Tuple(UInt64, Float32))) | Array(Array(Tuple(UInt64, Float64)))
  alias OfflineArrayMapStringNumericValue = Array(Array(Tuple(String, UInt8))) | Array(Array(Tuple(String, UInt16))) |
                                            Array(Array(Tuple(String, UInt32))) | Array(Array(Tuple(String, UInt64))) |
                                            Array(Array(Tuple(String, Int8))) | Array(Array(Tuple(String, Int16))) |
                                            Array(Array(Tuple(String, Int32))) | Array(Array(Tuple(String, Int64))) |
                                            Array(Array(Tuple(String, Float32))) | Array(Array(Tuple(String, Float64)))
  alias OfflineArrayMapUInt64NullableNumericValue = Array(Array(Tuple(UInt64, UInt8?))) | Array(Array(Tuple(UInt64, UInt16?))) |
                                                    Array(Array(Tuple(UInt64, UInt32?))) | Array(Array(Tuple(UInt64, UInt64?))) |
                                                    Array(Array(Tuple(UInt64, Int8?))) | Array(Array(Tuple(UInt64, Int16?))) |
                                                    Array(Array(Tuple(UInt64, Int32?))) | Array(Array(Tuple(UInt64, Int64?))) |
                                                    Array(Array(Tuple(UInt64, Float32?))) | Array(Array(Tuple(UInt64, Float64?)))
  alias OfflineArrayMapStringNullableNumericValue = Array(Array(Tuple(String, UInt8?))) | Array(Array(Tuple(String, UInt16?))) |
                                                    Array(Array(Tuple(String, UInt32?))) | Array(Array(Tuple(String, UInt64?))) |
                                                    Array(Array(Tuple(String, Int8?))) | Array(Array(Tuple(String, Int16?))) |
                                                    Array(Array(Tuple(String, Int32?))) | Array(Array(Tuple(String, Int64?))) |
                                                    Array(Array(Tuple(String, Float32?))) | Array(Array(Tuple(String, Float64?)))
  alias OfflineArrayMapUInt64ArrayNumericValue = Array(Array(Tuple(UInt64, Array(UInt8)))) | Array(Array(Tuple(UInt64, Array(UInt16)))) |
                                                 Array(Array(Tuple(UInt64, Array(UInt32)))) | Array(Array(Tuple(UInt64, Array(UInt64)))) |
                                                 Array(Array(Tuple(UInt64, Array(Int8)))) | Array(Array(Tuple(UInt64, Array(Int16)))) |
                                                 Array(Array(Tuple(UInt64, Array(Int32)))) | Array(Array(Tuple(UInt64, Array(Int64)))) |
                                                 Array(Array(Tuple(UInt64, Array(Float32)))) | Array(Array(Tuple(UInt64, Array(Float64))))
  alias OfflineArrayMapStringArrayNumericValue = Array(Array(Tuple(String, Array(UInt8)))) | Array(Array(Tuple(String, Array(UInt16)))) |
                                                 Array(Array(Tuple(String, Array(UInt32)))) | Array(Array(Tuple(String, Array(UInt64)))) |
                                                 Array(Array(Tuple(String, Array(Int8)))) | Array(Array(Tuple(String, Array(Int16)))) |
                                                 Array(Array(Tuple(String, Array(Int32)))) | Array(Array(Tuple(String, Array(Int64)))) |
                                                 Array(Array(Tuple(String, Array(Float32)))) | Array(Array(Tuple(String, Array(Float64))))

  alias OfflineColumnValue = UInt8 | UInt16 | UInt32 | UInt64 |
                             Int8 | Int16 | Int32 | Int64 | Int128 | UInt128 |
                             Float32 | Float64 | Bool | String | UUIDValue | IPv4Value | IPv6Value | QBitValue? |
                             Int256Value | UInt256Value | Decimal256Value | BFloat16Value | BFloat16Value? |
                             Array(UInt64) | Array(UInt64?) | Array(UInt8?) | Array(UInt16?) | Array(UInt32?) | Array(Int8?) | Array(Int16?) | Array(Int32?) | Array(Int64?) | Array(Float32?) | Array(Float64?) |
                             Array(String) | Array(String?) | Array(Array(UInt64)) | Array(Array(UInt64?)) | Array(Array(String)) |
                             Array(Array(String?)) |
                             Array(Array(Tuple(UInt64, Bool))) | Array(Array(Tuple(String, Bool))) |
                             Array(Array(Tuple(UInt64, Bool?))) | Array(Array(Tuple(String, Bool?))) |
                             Array(Array(UInt8?)) | Array(Array(UInt16?)) | Array(Array(UInt32?)) |
                             Array(Array(Int8?)) | Array(Array(Int16?)) | Array(Array(Int32?)) | Array(Array(Int64?)) |
                             Array(Array(Float32?)) | Array(Array(Float64?)) |
                             Array(Array(Int128?)) | Array(Array(UInt128?)) | Array(Array(Int256Value?)) | Array(Array(UInt256Value?)) | Array(Array(Decimal256Value?)) | Array(Array(BFloat16Value?)) |
                             Array(Array(UInt8)) | Array(Array(UInt16)) | Array(Array(UInt32)) |
                             Array(Array(Int8)) | Array(Array(Int16)) | Array(Array(Int32)) | Array(Array(Int64)) |
                             Array(Array(Float32)) | Array(Array(Float64)) |
                             Array(Array(Int128)) | Array(Array(UInt128)) | Array(Array(Int256Value)) | Array(Array(UInt256Value)) | Array(Array(Decimal256Value)) | Array(Array(BFloat16Value)) |
                             Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64) |
                             Array(Int128) | Array(UInt128) | Array(Int256Value) | Array(UInt256Value) |
                             Array(Int128?) | Array(UInt128?) | Array(Int256Value?) | Array(UInt256Value?) | Array(BFloat16Value?) |
                             Array(Decimal256Value) | Array(Decimal256Value?) |
                             Array(UUIDValue) | Array(UUIDValue?) | Array(IPv4Value) | Array(IPv4Value?) | Array(IPv6Value) | Array(IPv6Value?) |
                             Array(BFloat16Value) |
                             Array(Bool) | Array(Bool?) | Array(Array(Bool)) | Array(Array(Bool?)) |
                             Array(Tuple(UInt64, String)) | Array(Tuple(UInt64?, String)) | Array(Tuple(UInt64, UInt64)) |
                             Array(Tuple(String, UInt64)) | Array(Tuple(String, String)) |
                             Array(Array(Tuple(String, UInt64))) |
                             Array(Array(Tuple(UInt64, String))) | Array(Array(Tuple(String, String))) |
                             Array(Array(Tuple(UInt64, String?))) | Array(Array(Tuple(String, String?))) |
                             Array(Tuple(String, Array(UInt64))) |
                             Array(Tuple(String, Array(UInt8))) | Array(Tuple(String, Array(UInt16))) | Array(Tuple(String, Array(UInt32))) |
                             Array(Tuple(String, Array(Int8))) | Array(Tuple(String, Array(Int16))) | Array(Tuple(String, Array(Int32))) | Array(Tuple(String, Array(Int64))) |
                             Array(Tuple(String, Array(Float32))) | Array(Tuple(String, Array(Float64))) |
                             Array(Tuple(String, Array(UInt64?))) |
                             Array(Tuple(UInt64, Array(UInt64))) |
                             Array(Tuple(UInt64, Array(UInt8))) | Array(Tuple(UInt64, Array(UInt16))) | Array(Tuple(UInt64, Array(UInt32))) |
                             Array(Tuple(UInt64, Array(Int8))) | Array(Tuple(UInt64, Array(Int16))) | Array(Tuple(UInt64, Array(Int32))) | Array(Tuple(UInt64, Array(Int64))) |
                             Array(Tuple(UInt64, Array(Float32))) | Array(Tuple(UInt64, Array(Float64))) |
                             Array(Tuple(String, Array(String))) |
                             Array(Tuple(UInt64, Array(String))) |
                             OfflineArrayMapUInt64ArrayNumericValue |
                             OfflineArrayMapStringArrayNumericValue |
                             Array(Array(Tuple(UInt64, Array(String)))) |
                             Array(Array(Tuple(String, Array(String)))) |
                             Array(Tuple(String, Array(String?))) |
                             Array(Tuple(String, Array(UInt8?))) | Array(Tuple(String, Array(UInt16?))) | Array(Tuple(String, Array(UInt32?))) |
                             Array(Tuple(String, Array(Int8?))) | Array(Tuple(String, Array(Int16?))) | Array(Tuple(String, Array(Int32?))) | Array(Tuple(String, Array(Int64?))) |
                             Array(Tuple(String, Array(Float32?))) | Array(Tuple(String, Array(Float64?))) |
                             Array(Tuple(UInt64, Array(UInt64?))) |
                             Array(Tuple(UInt64, Array(UInt8?))) | Array(Tuple(UInt64, Array(UInt16?))) | Array(Tuple(UInt64, Array(UInt32?))) |
                             Array(Tuple(UInt64, Array(Int8?))) | Array(Tuple(UInt64, Array(Int16?))) | Array(Tuple(UInt64, Array(Int32?))) | Array(Tuple(UInt64, Array(Int64?))) |
                             Array(Tuple(UInt64, Array(Float32?))) | Array(Tuple(UInt64, Array(Float64?))) |
                             Array(Tuple(UInt64, Array(String?))) |
                             Array(Tuple(UInt64, UInt8)) | Array(Tuple(UInt64, UInt16)) | Array(Tuple(UInt64, UInt32)) |
                             Array(Tuple(UInt64, Int8)) | Array(Tuple(UInt64, Int16)) | Array(Tuple(UInt64, Int32)) |
                             Array(Tuple(UInt64, Int64)) | Array(Tuple(UInt64, Float32)) | Array(Tuple(UInt64, Float64)) |
                             Array(Tuple(String, UInt8)) | Array(Tuple(String, UInt16)) | Array(Tuple(String, UInt32)) |
                             Array(Tuple(String, Int8)) | Array(Tuple(String, Int16)) | Array(Tuple(String, Int32)) |
                             Array(Tuple(String, Int64)) | Array(Tuple(String, Float32)) | Array(Tuple(String, Float64)) |
                             Array(Tuple(UInt64, UInt64?)) | Array(Tuple(String, UInt64?)) |
                             Array(Tuple(UInt64, UInt8?)) | Array(Tuple(UInt64, UInt16?)) | Array(Tuple(UInt64, UInt32?)) |
                             Array(Tuple(UInt64, Int8?)) | Array(Tuple(UInt64, Int16?)) | Array(Tuple(UInt64, Int32?)) |
                             Array(Tuple(UInt64, Int64?)) | Array(Tuple(UInt64, Float32?)) | Array(Tuple(UInt64, Float64?)) |
                             Array(Tuple(String, UInt8?)) | Array(Tuple(String, UInt16?)) | Array(Tuple(String, UInt32?)) |
                             Array(Tuple(String, Int8?)) | Array(Tuple(String, Int16?)) | Array(Tuple(String, Int32?)) |
                             Array(Tuple(String, Int64?)) | Array(Tuple(String, Float32?)) | Array(Tuple(String, Float64?)) |
                             Array(Tuple(UInt64, String?)) | Array(Tuple(String, String?)) |
                             OfflineArrayMapUInt64NumericValue | OfflineArrayMapStringNumericValue |
                             OfflineArrayMapUInt64NullableNumericValue | OfflineArrayMapStringNullableNumericValue |
                             Tuple(UInt64, String) | WideTupleRow | WideArrayTupleRow | WideMapTupleRow | Nil
end
