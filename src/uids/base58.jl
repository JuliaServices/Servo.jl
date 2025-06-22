# Simple Base58 implementation
module Base58

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
const INDEXES = Dict{Char, Int}()

for (i, c) in enumerate(ALPHABET)
    INDEXES[c] = i - 1
end

function encode(input::AbstractVector{UInt8})::String
    if isempty(input)
        return ""
    end
    
    # Count leading zeroes
    zero_count = 0
    while zero_count < length(input) && input[zero_count + 1] == 0x00
        zero_count += 1
    end
    
    # Convert to base 58
    num = BigInt(0)
    for byte in input
        num = num * 256 + byte
    end
    
    # Convert to base 58 string
    if num == 0
        return "1" ^ zero_count
    end
    
    result = ""
    while num > 0
        num, remainder = divrem(num, 58)
        result = ALPHABET[remainder + 1] * result
    end
    
    # Add leading zeros
    return "1" ^ zero_count * result
end

function decode(input::String)::Vector{UInt8}
    if isempty(input)
        return UInt8[]
    end
    
    # Convert from base 58
    num = BigInt(0)
    for c in input
        digit = get(INDEXES, c, -1)
        if digit < 0
            throw(ArgumentError("Invalid Base58 character: $c"))
        end
        num = num * 58 + digit
    end
    
    # Convert to bytes
    if num == 0
        return UInt8[]
    end
    
    bytes = UInt8[]
    while num > 0
        num, remainder = divrem(num, 256)
        pushfirst!(bytes, UInt8(remainder))
    end
    
    # Add leading zeros
    zero_count = 0
    for c in input
        if c == '1'
            zero_count += 1
        else
            break
        end
    end
    
    return [zeros(UInt8, zero_count); bytes]
end

end # module 