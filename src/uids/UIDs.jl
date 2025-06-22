module UIDs

using Random

export UID, UID2, UID4, UID8, UID16, UID24, UID32, UID64
export encode_value, decode_value, bits_required, bitsize, StringN, SymbolN

include("base58.jl")
include("primitive_uids.jl")
include("encoders.jl")
include("uid.jl")

end # module 