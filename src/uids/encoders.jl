# Encoders for different data types
# These functions encode values into the first N bits of a UID

# Fixed-size string wrapper
struct StringN{N} <: AbstractString
    value::String
    function StringN{N}(s::String) where {N}
        if length(s) != N
            throw(ArgumentError("StringN{$N} must have length $N, got $(length(s))"))
        end
        new{N}(s)
    end
end

Base.length(s::StringN{N}) where {N} = N
Base.String(s::StringN{N}) where {N} = s.value
Base.show(io::IO, s::StringN{N}) where {N} = print(io, "StringN{$N}(\"$(s.value)\")")

# Iteration support for StringN
Base.iterate(s::StringN{N}) where {N} = iterate(s.value)
Base.iterate(s::StringN{N}, state::Integer) where {N} = iterate(s.value, state)

# Equality
Base.:(==)(a::StringN{N}, b::StringN{N}) where {N} = a.value == b.value
Base.:(==)(a::StringN{N}, b::String) where {N} = a.value == b

# Fixed-size symbol wrapper
struct SymbolN{N}
    value::Symbol
    function SymbolN{N}(s::Symbol) where {N}
        str = String(s)
        if length(str) != N
            throw(ArgumentError("SymbolN{$N} must have length $N, got $(length(str))"))
        end
        new{N}(s)
    end
end

Base.Symbol(s::SymbolN{N}) where {N} = s.value
Base.String(s::SymbolN{N}) where {N} = String(s.value)
Base.show(io::IO, s::SymbolN{N}) where {N} = print(io, "SymbolN{$N}(:$(s.value))")

# Iteration support for SymbolN
Base.iterate(s::SymbolN{N}) where {N} = iterate(String(s))
Base.iterate(s::SymbolN{N}, state::Integer) where {N} = iterate(String(s), state)

# Equality
Base.:(==)(a::SymbolN{N}, b::SymbolN{N}) where {N} = a.value == b.value
Base.:(==)(a::SymbolN{N}, b::Symbol) where {N} = a.value == b

# Calculate bits required for different types
function bits_required(x::Integer)
    if x < 0
        return 64  # Use 64 bits for negative integers
    elseif x == 0
        return 1
    else
        return Int(ceil(log2(x + 1)))
    end
end

function bits_required(::Type{T}) where {T<:Integer}
    return sizeof(T) * 8
end

function bits_required(x::AbstractFloat)
    return 64  # Use 64 bits for floats
end

function bits_required(::Type{<:AbstractFloat})
    return 64  # Use 64 bits for float types
end

function bits_required(x::Symbol)
    return length(String(x)) * 8  # 8 bits per character
end

function bits_required(::Type{Symbol})
    return 128  # Use 128 bits for symbol types (max 16 chars)
end

function bits_required(x::String)
    return length(x) * 8  # 8 bits per character
end

function bits_required(::Type{String})
    return 128  # Use 128 bits for string types (max 16 chars)
end

function bits_required(x::Char)
    return 32  # Use 32 bits for characters
end

function bits_required(::Type{Char})
    return 32  # Use 32 bits for char types
end

# Encode values into UInt128 (for the first part of larger UIDs)
function encode_value(x::Integer, bits::Int)
    if bits > 128
        throw(ArgumentError("Cannot encode $bits bits into UInt128"))
    end
    
    if x < 0
        # For negative integers, use two's complement
        # Convert to positive, then flip all bits and add 1
        abs_x = abs(x)
        if abs_x > (UInt128(1) << (bits - 1)) - 1
            throw(ArgumentError("Absolute value too large for $bits bits"))
        end
        return ((UInt128(1) << bits) - UInt128(abs_x)) & ((UInt128(1) << bits) - 1)
    else
        return UInt128(x) & ((UInt128(1) << bits) - 1)
    end
end

function encode_value(x::AbstractFloat, bits::Int)
    if bits > 64
        throw(ArgumentError("Cannot encode $bits bits for float"))
    end
    
    # Convert float to bits
    bits_float = reinterpret(UInt64, x)
    return UInt128(bits_float) & ((UInt128(1) << bits) - 1)
end

function encode_value(x::Symbol, bits::Int)
    if bits > 128
        throw(ArgumentError("Cannot encode $bits bits into UInt128"))
    end
    
    # Convert symbol to string and encode
    str = String(x)
    result = UInt128(0)
    for (i, c) in enumerate(str)
        if i * 8 > bits
            break
        end
        result |= UInt128(UInt8(c)) << ((i - 1) * 8)
    end
    return result & ((UInt128(1) << bits) - 1)
end

function encode_value(x::String, bits::Int)
    if bits > 128
        throw(ArgumentError("Cannot encode $bits bits into UInt128"))
    end
    
    result = UInt128(0)
    for (i, c) in enumerate(x)
        if i * 8 > bits
            break
        end
        result |= UInt128(UInt8(c)) << ((i - 1) * 8)
    end
    return result & ((UInt128(1) << bits) - 1)
end

function encode_value(x::Char, bits::Int)
    if bits > 32
        throw(ArgumentError("Cannot encode $bits bits for char"))
    end
    
    return UInt128(UInt32(x)) & ((UInt128(1) << bits) - 1)
end

# Decode values from UInt128
function decode_value(::Type{<:Integer}, encoded::UInt128, bits::Int)
    if bits > 64
        throw(ArgumentError("Cannot decode $bits bits for integer"))
    end
    
    # Extract the bits
    value = encoded & ((UInt128(1) << bits) - 1)
    # Always reinterpret as Int64 (two's complement)
    return reinterpret(Int64, UInt64(value))
end

function decode_value(::Type{<:AbstractFloat}, encoded::UInt128, bits::Int)
    if bits > 64
        throw(ArgumentError("Cannot decode $bits bits for float"))
    end
    
    # Extract the bits and convert back to float
    value = encoded & ((UInt128(1) << bits) - 1)
    return reinterpret(Float64, UInt64(value))
end

function decode_value(::Type{Symbol}, encoded::UInt128, bits::Int)
    if bits > 128
        throw(ArgumentError("Cannot decode $bits bits for symbol"))
    end
    
    # Extract characters
    chars = Char[]
    for i in 1:min(bits ÷ 8, 16)  # Max 16 characters for UInt128
        char_bits = (encoded >> ((i - 1) * 8)) & 0xFF
        if char_bits == 0
            break
        end
        push!(chars, Char(UInt8(char_bits)))
    end
    
    return Symbol(String(chars))
end

function decode_value(::Type{String}, encoded::UInt128, bits::Int)
    if bits > 128
        throw(ArgumentError("Cannot decode $bits bits for string"))
    end
    
    # Extract characters
    chars = Char[]
    for i in 1:min(bits ÷ 8, 16)  # Max 16 characters for UInt128
        char_bits = (encoded >> ((i - 1) * 8)) & 0xFF
        if char_bits == 0
            break
        end
        push!(chars, Char(UInt8(char_bits)))
    end
    
    return String(chars)
end

function decode_value(::Type{Char}, encoded::UInt128, bits::Int)
    if bits > 32
        throw(ArgumentError("Cannot decode $bits bits for char"))
    end
    
    # Extract the character bits
    value = encoded & ((UInt128(1) << bits) - 1)
    return Char(UInt32(value))
end

# bits_required for StringN{N}
bits_required(::Type{StringN{N}}) where {N} = N * 8
bits_required(x::StringN{N}) where {N} = N * 8

# encode_value for StringN{N}
function encode_value(x::StringN{N}, bits::Int) where {N}
    if bits != N * 8
        throw(ArgumentError("bits for StringN{$N} must be N*8, got $bits"))
    end
    result = UInt128(0)
    for i in 1:N
        c = x.value[i]
        result |= UInt128(UInt8(c)) << ((i - 1) * 8)
    end
    return result
end

# decode_value for StringN{N}
function decode_value(::Type{StringN{N}}, encoded::UInt128, bits::Int) where {N}
    if bits != N * 8
        throw(ArgumentError("bits for StringN{$N} must be N*8, got $bits"))
    end
    chars = Char[]
    for i in 1:N
        char_bits = (encoded >> ((i - 1) * 8)) & 0xFF
        push!(chars, Char(UInt8(char_bits)))
    end
    return StringN{N}(String(chars))
end

# bits_required for SymbolN{N}
bits_required(::Type{SymbolN{N}}) where {N} = N * 8
bits_required(x::SymbolN{N}) where {N} = N * 8

# encode_value for SymbolN{N}
function encode_value(x::SymbolN{N}, bits::Int) where {N}
    if bits != N * 8
        throw(ArgumentError("bits for SymbolN{$N} must be N*8, got $bits"))
    end
    result = UInt128(0)
    str = String(x.value)
    for i in 1:N
        c = str[i]
        result |= UInt128(UInt8(c)) << ((i - 1) * 8)
    end
    return result
end

# decode_value for SymbolN{N}
function decode_value(::Type{SymbolN{N}}, encoded::UInt128, bits::Int) where {N}
    if bits != N * 8
        throw(ArgumentError("bits for SymbolN{$N} must be N*8, got $bits"))
    end
    chars = Char[]
    for i in 1:N
        char_bits = (encoded >> ((i - 1) * 8)) & 0xFF
        push!(chars, Char(UInt8(char_bits)))
    end
    str = String(chars)
    # Strip trailing null characters
    str = rstrip(str, '\0')
    return SymbolN{N}(Symbol(str))
end

# bits_required for Enum types
function bits_required(::Type{T}) where {T<:Enum}
    return sizeof(Base.Enums.basetype(T)) * 8
end
function bits_required(x::Enum)
    return bits_required(typeof(x))
end

# encode_value for Enum types
function encode_value(x::Enum, bits::Int)
    return encode_value(Int(x), bits)
end

# decode_value for Enum types
function decode_value(::Type{T}, encoded::UInt128, bits::Int) where {T<:Enum}
    int_val = decode_value(Base.Enums.basetype(T), encoded, bits)
    return T(int_val)
end 