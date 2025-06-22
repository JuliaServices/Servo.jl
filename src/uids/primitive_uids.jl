# Primitive UID types with different bit sizes
primitive type UID2 <: Integer 16 end
primitive type UID4 <: Integer 32 end
primitive type UID8 <: Integer 64 end
primitive type UID16 <: Integer 128 end
primitive type UID24 <: Integer 192 end
primitive type UID32 <: Integer 256 end
primitive type UID64 <: Integer 512 end

# Constructor functions for each primitive type
UID2() = reinterpret(UID2, rand(UInt16))
UID4() = reinterpret(UID4, rand(UInt32))
UID8() = reinterpret(UID8, rand(UInt64))
UID16() = reinterpret(UID16, rand(UInt128))
UID24() = reinterpret(UID24, (rand(UInt128), rand(UInt64)))
UID32() = reinterpret(UID32, (rand(UInt128), rand(UInt128)))
UID64() = reinterpret(UID64, (rand(UInt128), rand(UInt128), rand(UInt128), rand(UInt128)))

# Convert from integers
UID2(x::UInt16) = reinterpret(UID2, x)
UID4(x::UInt32) = reinterpret(UID4, x)
UID8(x::UInt64) = reinterpret(UID8, x)
UID16(x::UInt128) = reinterpret(UID16, x)
UID24(x::Tuple{UInt128, UInt64}) = reinterpret(UID24, x)
UID32(x::Tuple{UInt128, UInt128}) = reinterpret(UID32, x)
UID64(x::Tuple{UInt128, UInt128, UInt128, UInt128}) = reinterpret(UID64, x)

# Convert to integers
Base.UInt16(x::UID2) = reinterpret(UInt16, x)
Base.UInt32(x::UID4) = reinterpret(UInt32, x)
Base.UInt64(x::UID8) = reinterpret(UInt64, x)
Base.UInt128(x::UID16) = reinterpret(UInt128, x)

# Convert to tuples for larger types
Base.Tuple(x::UID24) = reinterpret(Tuple{UInt128, UInt64}, x)
Base.Tuple(x::UID32) = reinterpret(Tuple{UInt128, UInt128}, x)
Base.Tuple(x::UID64) = reinterpret(Tuple{UInt128, UInt128, UInt128, UInt128}, x)

# Convert any UID to UInt128 for encoding/decoding
function Base.UInt128(x::UID2)
    return UInt128(UInt16(x))
end

function Base.UInt128(x::UID4)
    return UInt128(UInt32(x))
end

function Base.UInt128(x::UID8)
    return UInt128(UInt64(x))
end

function Base.UInt128(x::UID24)
    t = Tuple(x)
    return t[1] | (UInt128(t[2]) << 64)
end

function Base.UInt128(x::UID32)
    t = Tuple(x)
    return t[1] | (t[2] << 64)
end

function Base.UInt128(x::UID64)
    t = Tuple(x)
    return t[1] | (t[2] << 64) | (t[3] << 128) | (t[4] << 192)
end

# String representation using Base58
function Base.string(x::UID2)
    bytes = reinterpret(UInt8, [UInt16(x)])
    return Base58.encode(bytes)
end

function Base.string(x::UID4)
    bytes = reinterpret(UInt8, [UInt32(x)])
    return Base58.encode(bytes)
end

function Base.string(x::UID8)
    bytes = reinterpret(UInt8, [UInt64(x)])
    return Base58.encode(bytes)
end

function Base.string(x::UID16)
    bytes = reinterpret(UInt8, [UInt128(x)])
    return Base58.encode(bytes)
end

function Base.string(x::UID24)
    t = Tuple(x)
    bytes = reinterpret(UInt8, [t[1], t[2]])
    return Base58.encode(bytes)
end

function Base.string(x::UID32)
    t = Tuple(x)
    bytes = reinterpret(UInt8, [t[1], t[2]])
    return Base58.encode(bytes)
end

function Base.string(x::UID64)
    t = Tuple(x)
    bytes = reinterpret(UInt8, [t[1], t[2], t[3], t[4]])
    return Base58.encode(bytes)
end

# Show methods
Base.show(io::IO, x::UID2) = print(io, "UID2\"$(string(x))\"")
Base.show(io::IO, x::UID4) = print(io, "UID4\"$(string(x))\"")
Base.show(io::IO, x::UID8) = print(io, "UID8\"$(string(x))\"")
Base.show(io::IO, x::UID16) = print(io, "UID16\"$(string(x))\"")
Base.show(io::IO, x::UID24) = print(io, "UID24\"$(string(x))\"")
Base.show(io::IO, x::UID32) = print(io, "UID32\"$(string(x))\"")
Base.show(io::IO, x::UID64) = print(io, "UID64\"$(string(x))\"")

# Get bit size for each type
bitsize(::Type{UID2}) = 16
bitsize(::Type{UID4}) = 32
bitsize(::Type{UID8}) = 64
bitsize(::Type{UID16}) = 128
bitsize(::Type{UID24}) = 192
bitsize(::Type{UID32}) = 256
bitsize(::Type{UID64}) = 512 