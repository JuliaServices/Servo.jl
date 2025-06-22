# Helper function to automatically wrap strings with StringN{N}
function wrap_string(s::String)
    return StringN{length(s)}(s)
end

wrap_string(x) = x  # Identity for non-strings

# Helper function to automatically wrap symbols with SymbolN{N}
function wrap_symbol(s::Symbol)
    return SymbolN{length(String(s))}(s)
end

wrap_symbol(x) = x  # Identity for non-symbols

# Helper function to encode values across multiple words
function encode_multi_word(args, types, uid_type)
    total_bits = sum(bits_required(T) for T in types)
    available_bits = bitsize(uid_type)
    
    if total_bits > available_bits
        throw(ArgumentError("Need $total_bits bits but only have $available_bits available in $uid_type"))
    end
    
    # Create a random UID first to get random bits
    random_uid = uid_type()
    
    # Initialize words based on UID type, using random values
    if uid_type == UID2
        words = [UInt16(random_uid)]
        word_sizes = [16]
    elseif uid_type == UID4
        words = [UInt32(random_uid)]
        word_sizes = [32]
    elseif uid_type == UID8
        words = [UInt64(random_uid)]
        word_sizes = [64]
    elseif uid_type == UID16
        words = [UInt128(random_uid)]
        word_sizes = [128]
    elseif uid_type == UID24
        t = Tuple(random_uid)
        words = [UInt128(t[1]), UInt64(t[2])]
        word_sizes = [128, 64]
    elseif uid_type == UID32
        t = Tuple(random_uid)
        words = [UInt128(t[1]), UInt128(t[2])]
        word_sizes = [128, 128]
    elseif uid_type == UID64
        t = Tuple(random_uid)
        words = [UInt128(t[1]), UInt128(t[2]), UInt128(t[3]), UInt128(t[4])]
        word_sizes = [128, 128, 128, 128]
    end
    
    # Encode values across words, preserving random bits in unused portions
    bit_offset = 0
    for (arg, T) in zip(args, types)
        bits_needed = bits_required(T)
        encoded_value = encode_value(arg, bits_needed)
        
        # Distribute encoded value across words
        remaining_bits = bits_needed
        value_offset = 0
        
        while remaining_bits > 0
            # Find which word we're in
            word_idx = 1
            word_bit_offset = bit_offset
            for i in 1:length(word_sizes)
                if word_bit_offset < word_sizes[i]
                    word_idx = i
                    break
                end
                word_bit_offset -= word_sizes[i]
            end
            
            bits_in_word = min(remaining_bits, word_sizes[word_idx] - word_bit_offset)
            
            # Extract the relevant bits from encoded_value
            mask = (UInt128(1) << bits_in_word) - 1
            bits_to_write = (encoded_value >> value_offset) & mask
            
            # Clear the target bits and write the encoded value
            clear_mask = ~(mask << word_bit_offset)
            words[word_idx] = (words[word_idx] & clear_mask) | (bits_to_write << word_bit_offset)
            
            remaining_bits -= bits_in_word
            value_offset += bits_in_word
            bit_offset += bits_in_word
        end
    end
    
    return words
end

# Helper function to decode values from multiple words
function decode_multi_word(uid, types, uid_type)
    # Extract words from UID based on the primitive UID type
    if uid_type == UID2
        words = [UInt128(uid)]
        word_sizes = [16]
    elseif uid_type == UID4
        words = [UInt128(uid)]
        word_sizes = [32]
    elseif uid_type == UID8
        words = [UInt128(uid)]
        word_sizes = [64]
    elseif uid_type == UID16
        words = [UInt128(uid)]
        word_sizes = [128]
    elseif uid_type == UID24
        t = Tuple(uid)
        words = [UInt128(t[1]), UInt128(t[2])]
        word_sizes = [128, 64]
    elseif uid_type == UID32
        t = Tuple(uid)
        words = [UInt128(t[1]), UInt128(t[2])]
        word_sizes = [128, 128]
    elseif uid_type == UID64
        t = Tuple(uid)
        words = [UInt128(t[1]), UInt128(t[2]), UInt128(t[3]), UInt128(t[4])]
        word_sizes = [128, 128, 128, 128]
    end
    
    # Decode values from words
    decoded = []
    bit_offset = 0
    
    for T in types
        bits_needed = bits_required(T)
        encoded_value = UInt128(0)
        
        # Collect bits from words
        remaining_bits = bits_needed
        value_offset = 0
        
        while remaining_bits > 0
            # Find which word we're in
            word_idx = 1
            word_bit_offset = bit_offset
            for i in 1:length(word_sizes)
                if word_bit_offset < word_sizes[i]
                    word_idx = i
                    break
                end
                word_bit_offset -= word_sizes[i]
            end
            
            bits_in_word = min(remaining_bits, word_sizes[word_idx] - word_bit_offset)
            
            # Extract bits from the word
            mask = (UInt128(1) << bits_in_word) - 1
            bits_from_word = (words[word_idx] >> word_bit_offset) & mask
            
            # Add to encoded_value
            encoded_value |= bits_from_word << value_offset
            
            remaining_bits -= bits_in_word
            value_offset += bits_in_word
            bit_offset += bits_in_word
        end
        
        # Decode the value
        push!(decoded, decode_value(T, encoded_value, bits_needed))
    end
    
    return decoded
end

# Main UID type that can store encoded values
struct UID{T, U <: Union{UID2, UID4, UID8, UID16, UID24, UID32, UID64}}
    uid::U
end

# Constructor that takes any number of arguments and encodes them
function UID(args...; uid_type::Type{<:Union{UID2, UID4, UID8, UID16, UID24, UID32, UID64}} = UID8)
    if isempty(args)
        return UID{Nothing, uid_type}(uid_type())
    end
    
    # Wrap strings with StringN{N} and symbols with SymbolN{N} automatically
    wrapped_args = map(wrap_string ∘ wrap_symbol, args)
    types = map(typeof, wrapped_args)
    
    # Calculate total bits needed using type-based widths
    total_bits = sum(bits_required(T) for T in types)
    
    # Check maximum size limit (UID64 = 512 bits)
    max_bits = 512
    if total_bits > max_bits
        throw(ArgumentError("Total bits required ($total_bits) exceeds maximum supported size ($max_bits bits). Use fewer or smaller arguments."))
    end
    
    # Encode values across multiple words
    words = encode_multi_word(wrapped_args, types, uid_type)
    
    # Create the UID with encoded values
    if uid_type == UID2
        uid = UID2(UInt16(words[1]))
    elseif uid_type == UID4
        uid = UID4(UInt32(words[1]))
    elseif uid_type == UID8
        uid = UID8(UInt64(words[1]))
    elseif uid_type == UID16
        uid = UID16(words[1])
    elseif uid_type == UID24
        uid = UID24((words[1], words[2]))
    elseif uid_type == UID32
        uid = UID32((words[1], words[2]))
    elseif uid_type == UID64
        uid = UID64((words[1], words[2], words[3], words[4]))
    end
    
    return UID{Tuple{map(typeof, wrapped_args)...}, uid_type}(uid)
end

# Constructor with specific UID type
function UID(uid_type::Type{<:Union{UID2, UID4, UID8, UID16, UID24, UID32, UID64}}, args...)
    return UID(args...; uid_type=uid_type)
end

# String representation
function Base.string(uid::UID)
    return string(uid.uid)
end

# Show method
function Base.show(io::IO, uid::UID)
    print(io, "UID\"$(string(uid))\"")
end

# Helper function to unwrap StringN and SymbolN values
function unwrap_value(value)
    if value isa StringN
        return String(value)
    elseif value isa SymbolN
        return Symbol(value)
    else
        return value
    end
end

# Indexing to extract original values
function Base.getindex(uid::UID{T, U}, i::Integer) where {T, U}
    if T == Nothing
        throw(BoundsError(uid, i))
    end
    
    args = T.parameters
    if i < 1 || i > length(args)
        throw(BoundsError(uid, i))
    end
    
    # Use multi-word decoding to get all values
    decoded_values = decode_multi_word(uid.uid, args, U)
    # Automatically unwrap StringN and SymbolN values
    return unwrap_value(decoded_values[i])
end

# Length of the tuple
function Base.length(uid::UID{T}) where T
    return T == Nothing ? 0 : length(T.parameters)
end

# Iterator support
function Base.iterate(uid::UID{T}) where T
    if T == Nothing || isempty(T.parameters)
        return nothing
    end
    return (uid[1], 1)
end

function Base.iterate(uid::UID{T}, state::Integer) where T
    if state >= length(uid)
        return nothing
    end
    return (uid[state + 1], state + 1)
end

# Convert to tuple
function Base.Tuple(uid::UID{T}) where T
    if T == Nothing
        return ()
    end
    return Tuple([uid[i] for i in 1:length(uid)])
end

# Equality
function Base.:(==)(a::UID, b::UID)
    if typeof(a) !== typeof(b)
        return false
    end
    return a.uid == b.uid
end

# Hash
function Base.hash(uid::UID, h::UInt)
    return hash(UInt128(uid.uid), h)
end 