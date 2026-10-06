module CrystalClick
  alias WidePartNumericArray = Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                               Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Int128) | Array(UInt128) | Array(Bool) |
                               Array(Float32) | Array(Float64) | Array(UUIDValue) | Array(IPv4Value) | Array(IPv6Value) |
                               Array(Int256Value) | Array(UInt256Value) | Array(Decimal256Value) | Array(BFloat16Value)
  alias WidePartNumericSlice = Slice(UInt8) | Slice(UInt16) | Slice(UInt32) | Slice(UInt64) |
                               Slice(Int8) | Slice(Int16) | Slice(Int32) | Slice(Int64) | Slice(Int128) | Slice(UInt128) | Slice(Bool) |
                               Slice(Float32) | Slice(Float64) | Slice(UUIDValue) | Slice(IPv4Value) | Slice(IPv6Value) |
                               Slice(Int256Value) | Slice(UInt256Value) | Slice(Decimal256Value) | Slice(BFloat16Value)
  alias WidePartNullableArray = Array(UInt8?) | Array(UInt16?) | Array(UInt32?) | Array(UInt64?) |
                                Array(Int8?) | Array(Int16?) | Array(Int32?) | Array(Int64?) | Array(Int128?) | Array(UInt128?) | Array(Bool?) |
                                Array(Float32?) | Array(Float64?) | Array(UUIDValue?) | Array(IPv4Value?) | Array(IPv6Value?) |
                                Array(Int256Value?) | Array(UInt256Value?) | Array(Decimal256Value?) | Array(BFloat16Value?)
  alias WidePartNullableSlice = Slice(UInt8?) | Slice(UInt16?) | Slice(UInt32?) | Slice(UInt64?) |
                                Slice(Int8?) | Slice(Int16?) | Slice(Int32?) | Slice(Int64?) | Slice(Int128?) | Slice(UInt128?) | Slice(Bool?) |
                                Slice(Float32?) | Slice(Float64?) | Slice(UUIDValue?) | Slice(IPv4Value?) | Slice(IPv6Value?) |
                                Slice(Int256Value?) | Slice(UInt256Value?) | Slice(Decimal256Value?) | Slice(BFloat16Value?)
  alias WidePartNullableStringArray = Array(String?)
  alias WidePartNullableStringSlice = Slice(String?)
  alias WidePartArrayNumericArray = Array(Array(UInt8)) | Array(Array(UInt16)) | Array(Array(UInt32)) | Array(Array(UInt64)) |
                                    Array(Array(Int8)) | Array(Array(Int16)) | Array(Array(Int32)) | Array(Array(Int64)) |
                                    Array(Array(Float32)) | Array(Array(Float64)) |
                                    Array(Array(Int128)) | Array(Array(UInt128)) | Array(Array(Int256Value)) | Array(Array(UInt256Value)) |
                                    Array(Array(UUIDValue)) | Array(Array(IPv4Value)) | Array(Array(IPv6Value)) | Array(Array(Decimal256Value)) | Array(Array(BFloat16Value))
  alias WidePartArrayNumericSlice = Slice(Array(UInt8)) | Slice(Array(UInt16)) | Slice(Array(UInt32)) | Slice(Array(UInt64)) |
                                    Slice(Array(Int8)) | Slice(Array(Int16)) | Slice(Array(Int32)) | Slice(Array(Int64)) |
                                    Slice(Array(Float32)) | Slice(Array(Float64)) |
                                    Slice(Array(Int128)) | Slice(Array(UInt128)) | Slice(Array(Int256Value)) | Slice(Array(UInt256Value)) |
                                    Slice(Array(UUIDValue)) | Slice(Array(IPv4Value)) | Slice(Array(IPv6Value)) | Slice(Array(Decimal256Value)) | Slice(Array(BFloat16Value))
  alias WidePartArrayNullableNumericArray = Array(Array(UInt8?)) | Array(Array(UInt16?)) | Array(Array(UInt32?)) | Array(Array(UInt64?)) |
                                            Array(Array(Int8?)) | Array(Array(Int16?)) | Array(Array(Int32?)) | Array(Array(Int64?)) |
                                            Array(Array(Float32?)) | Array(Array(Float64?)) |
                                            Array(Array(Int128?)) | Array(Array(UInt128?)) | Array(Array(Int256Value?)) | Array(Array(UInt256Value?)) |
                                            Array(Array(UUIDValue?)) | Array(Array(IPv4Value?)) | Array(Array(IPv6Value?)) | Array(Array(Decimal256Value?)) | Array(Array(BFloat16Value?))
  alias WidePartArrayNullableNumericSlice = Slice(Array(UInt8?)) | Slice(Array(UInt16?)) | Slice(Array(UInt32?)) | Slice(Array(UInt64?)) |
                                            Slice(Array(Int8?)) | Slice(Array(Int16?)) | Slice(Array(Int32?)) | Slice(Array(Int64?)) |
                                            Slice(Array(Float32?)) | Slice(Array(Float64?)) |
                                            Slice(Array(Int128?)) | Slice(Array(UInt128?)) | Slice(Array(Int256Value?)) | Slice(Array(UInt256Value?)) |
                                            Slice(Array(UUIDValue?)) | Slice(Array(IPv4Value?)) | Slice(Array(IPv6Value?)) | Slice(Array(Decimal256Value?)) | Slice(Array(BFloat16Value?))
  alias WidePartArrayNullableStringArray = Array(Array(String?))
  alias WidePartArrayNullableStringSlice = Slice(Array(String?))
  alias WidePartArrayArrayNullableStringArray = Array(Array(Array(String?)))
  alias WidePartArrayArrayNullableStringSlice = Slice(Array(Array(String?)))
  alias WidePartArrayArrayNumericArray = Array(Array(Array(UInt8))) | Array(Array(Array(UInt16))) | Array(Array(Array(UInt32))) | Array(Array(Array(UInt64))) |
                                         Array(Array(Array(Int8))) | Array(Array(Array(Int16))) | Array(Array(Array(Int32))) | Array(Array(Array(Int64))) |
                                         Array(Array(Array(Float32))) | Array(Array(Array(Float64))) |
                                         Array(Array(Array(Int128))) | Array(Array(Array(UInt128))) |
                                         Array(Array(Array(Int256Value))) | Array(Array(Array(UInt256Value))) | Array(Array(Array(Decimal256Value))) | Array(Array(Array(BFloat16Value)))
  alias WidePartArrayArrayNumericSlice = Slice(Array(Array(UInt8))) | Slice(Array(Array(UInt16))) | Slice(Array(Array(UInt32))) | Slice(Array(Array(UInt64))) |
                                         Slice(Array(Array(Int8))) | Slice(Array(Array(Int16))) | Slice(Array(Array(Int32))) | Slice(Array(Array(Int64))) |
                                         Slice(Array(Array(Float32))) | Slice(Array(Array(Float64))) |
                                         Slice(Array(Array(Int128))) | Slice(Array(Array(UInt128))) |
                                         Slice(Array(Array(Int256Value))) | Slice(Array(Array(UInt256Value))) | Slice(Array(Array(Decimal256Value))) | Slice(Array(Array(BFloat16Value)))
  alias WidePartArrayArrayNullableNumericArray = Array(Array(Array(UInt8?))) | Array(Array(Array(UInt16?))) | Array(Array(Array(UInt32?))) | Array(Array(Array(UInt64?))) |
                                                 Array(Array(Array(Int8?))) | Array(Array(Array(Int16?))) | Array(Array(Array(Int32?))) | Array(Array(Array(Int64?))) |
                                                 Array(Array(Array(Float32?))) | Array(Array(Array(Float64?))) |
                                                 Array(Array(Array(Int128?))) | Array(Array(Array(UInt128?))) |
                                                 Array(Array(Array(Int256Value?))) | Array(Array(Array(UInt256Value?))) | Array(Array(Array(Decimal256Value?))) | Array(Array(Array(BFloat16Value?)))
  alias WidePartArrayArrayNullableNumericSlice = Slice(Array(Array(UInt8?))) | Slice(Array(Array(UInt16?))) | Slice(Array(Array(UInt32?))) | Slice(Array(Array(UInt64?))) |
                                                 Slice(Array(Array(Int8?))) | Slice(Array(Array(Int16?))) | Slice(Array(Array(Int32?))) | Slice(Array(Array(Int64?))) |
                                                 Slice(Array(Array(Float32?))) | Slice(Array(Array(Float64?))) |
                                                 Slice(Array(Array(Int128?))) | Slice(Array(Array(UInt128?))) |
                                                 Slice(Array(Array(Int256Value?))) | Slice(Array(Array(UInt256Value?))) | Slice(Array(Array(Decimal256Value?))) | Slice(Array(Array(BFloat16Value?)))
  alias WidePartArrayBoolArray = Array(Array(Bool))
  alias WidePartArrayBoolSlice = Slice(Array(Bool))
  alias WidePartArrayNullableBoolArray = Array(Array(Bool?))
  alias WidePartArrayNullableBoolSlice = Slice(Array(Bool?))

end
