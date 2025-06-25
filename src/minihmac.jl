module MiniHMAC

using LibAwsCommon, LibAwsCal, Base64
import ..getConfig

export generate_token, verify_token, TokenPayload, is_expired

"""
    TokenPayload

Represents the payload data for an HMAC token.
"""
struct TokenPayload
    user_id::String
    issued_at::Int64
    exp::Int64
end

TokenPayload(uid, iat::Float64, exp::Float64) = TokenPayload(uid, trunc(Int64, iat), trunc(Int64, exp))

"""
    Get the current signing key from configuration
"""
function get_current_signing_key()
    hmac_config = getConfig("hmac")
    if hmac_config === nothing
        throw(ArgumentError("HMAC configuration not found. Please set 'hmac.signing.key' in config."))
    end
    signing_config = get(hmac_config, "signing", nothing)
    if signing_config === nothing
        throw(ArgumentError("HMAC signing configuration not found. Please set 'hmac.signing.key' in config."))
    end
    key = get(signing_config, "key", nothing)
    if key === nothing
        throw(ArgumentError("HMAC signing key not found. Please set 'hmac.signing.key' in config."))
    end
    return Vector{UInt8}(key)
end

"""
    Get the secondary signing key from configuration (for key rotation)
"""
function get_secondary_signing_key()
    hmac_config = getConfig("hmac")
    if hmac_config === nothing
        return nothing
    end
    signing_config = get(hmac_config, "signing", nothing)
    if signing_config === nothing
        return nothing
    end
    key2 = get(signing_config, "key2", nothing)
    if key2 === nothing
        return nothing
    end
    return Vector{UInt8}(key2)
end

"""
    Base64URL encoding without padding
"""
function base64url_encode(data::Vector{UInt8})
    # Use standard base64 encoding, then replace characters and remove padding
    encoded = base64encode(data)
    # Replace URL-unsafe characters
    encoded = replace(encoded, '+' => '-', '/' => '_')
    # Remove padding
    encoded = rstrip(encoded, '=')
    return encoded
end

"""
    Base64URL decoding
"""
function base64url_decode(encoded::String)
    # Add padding back if needed
    padding_needed = 4 - (length(encoded) % 4)
    if padding_needed != 4
        encoded = encoded * repeat("=", padding_needed)
    end
    # Replace URL-safe characters back
    encoded = replace(encoded, '-' => '+', '_' => '/')
    return base64decode(encoded)
end

"""
    Serialize payload to string format: user_id:issued_at:exp
"""
function serialize_payload(payload::TokenPayload)
    return "$(payload.user_id):$(payload.issued_at):$(payload.exp)"
end

"""
    Parse payload from string format: user_id:issued_at:exp
"""
function parse_payload(payload_str::String)
    parts = split(payload_str, ':')
    if length(parts) != 3
        throw(ArgumentError("Invalid payload format: expected 3 parts, got $(length(parts))"))
    end
    return TokenPayload(
        parts[1],                    # user_id
        parse(Int64, parts[2]),      # issued_at
        parse(Int64, parts[3])       # exp
    )
end

"""
    Generate HMAC-SHA256 signature using LibAwsCal
"""
function generate_signature(secret::Vector{UInt8}, payload::String)
    GC.@preserve secret payload begin
        secret_cursor = aws_byte_cursor_from_array(pointer(secret), sizeof(secret))
        payload_cursor = aws_byte_cursor_from_array(pointer(payload), sizeof(payload))
        # Create HMAC instance
        hmac = aws_sha256_hmac_new(default_aws_allocator(), Ref(secret_cursor))
        @assert hmac != C_NULL "Failed to create HMAC instance"
        try
            # Update with payload
            result = aws_hmac_update(hmac, Ref(payload_cursor))
            @assert result == 0 "HMAC update failed: $(unsafe_string(aws_error_str(aws_last_error())))"
            # Finalize and get signature
            output_buf = Ref(aws_byte_buf(0, C_NULL, 0, C_NULL))
            aws_byte_buf_init(output_buf, default_aws_allocator(), AWS_SHA256_HMAC_LEN)
            try
                result = aws_hmac_finalize(hmac, output_buf, 0)
                @assert result == 0 "HMAC finalize failed: $(unsafe_string(aws_error_str(aws_last_error())))"
                # Extract signature bytes
                cursor = aws_byte_cursor_from_buf(output_buf)
                signature = Vector{UInt8}(undef, cursor.len)
                unsafe_copyto!(pointer(signature), cursor.ptr, cursor.len)
                return signature
            finally
                aws_byte_buf_clean_up(output_buf)
            end
        finally
            aws_hmac_destroy(hmac)
        end
    end
end

"""
    Generate HMAC token using current signing key from config

    token := BASE64URL(payload) "." BASE64URL(sig)
    payload := user_id ":" issued_at_unix ":" exp_unix
    sig := HMAC‑SHA256(secret, payload)

    # Arguments:
    - `payload`: TokenPayload struct containing user_id, issued_at, and exp
"""
function generate_token(payload::TokenPayload)
    secret = get_current_signing_key()
    return generate_token_with_secret(secret, payload)
end

"""
    Generate HMAC token with explicit secret (internal use)
"""
function generate_token_with_secret(secret::Vector{UInt8}, payload::TokenPayload)
    # Serialize payload
    payload_str = serialize_payload(payload)
    payload_bytes = Vector{UInt8}(payload_str)
    # Generate signature
    signature = generate_signature(secret, payload_str)
    # Encode both parts with Base64URL
    encoded_payload = base64url_encode(payload_bytes)
    encoded_signature = base64url_encode(signature)
    # Combine with dot separator
    return "$(encoded_payload).$(encoded_signature)"
end

"""
    Verify HMAC token with key rotation support

    First tries the current signing key, then falls back to the secondary key
    if the first verification fails. Also checks if the token is expired.
    Returns the parsed payload if verification succeeds, throws error otherwise.
"""
function verify_token(token::String)
    # Split token into payload and signature parts
    parts = split(token, '.')
    if length(parts) != 2
        throw(ArgumentError("Invalid token format: expected 2 parts separated by '.', got $(length(parts))"))
    end
    encoded_payload, encoded_signature = parts
    # Decode payload
    payload_bytes = base64url_decode(String(encoded_payload))
    payload_str = String(payload_bytes)
    # Parse payload
    payload = parse_payload(payload_str)
    # Check if token is expired
    if is_expired(payload)
        throw(ArgumentError("Token has expired"))
    end
    # Try current signing key first
    current_secret = get_current_signing_key()
    if verify_token_with_secret(current_secret, token, payload_str, String(encoded_signature))
        return payload
    end
    # If current key fails, try secondary key
    secondary_secret = get_secondary_signing_key()
    if secondary_secret !== nothing
        if verify_token_with_secret(secondary_secret, token, payload_str, String(encoded_signature))
            return payload
        end
    end
    # Both keys failed
    throw(ArgumentError("Invalid signature - token verification failed with both current and secondary keys"))
end

"""
    Verify token with specific secret (internal use)
"""
function verify_token_with_secret(secret::Vector{UInt8}, token::String, payload_str::String, encoded_signature::String)
    try
        # Verify signature
        expected_signature = generate_signature(secret, payload_str)
        actual_signature = base64url_decode(encoded_signature)
        if length(expected_signature) != length(actual_signature)
            return false
        end
        # Constant-time comparison
        return all(expected_signature .== actual_signature)
    catch
        return false
    end
end

"""
    Convenience function to generate token with current timestamp
"""
function generate_token(user_id::String; issued_at::Int64=trunc(Int64, time()), exp::Int64=issued_at + 3600)
    payload = TokenPayload(user_id, issued_at, exp)
    return generate_token(payload)
end

"""
    Check if token is expired
"""
function is_expired(payload::TokenPayload)
    return time() > payload.exp
end

"""
    Check if token is expired (convenience function)
"""
function is_expired(token::String)
    payload = verify_token(token)
    return is_expired(payload)
end

end # module 