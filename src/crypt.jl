module Crypt

using LibAwsCommon, LibAwsCal, Random, SHA, Base64

export encrypt, decrypt

# --- PBKDF2-HMAC-SHA256 deriving 48 bytes (32 key + 16 IV)
function derive_key_and_iv(password::Vector{UInt8}, salt::Vector{UInt8}; iters::Int=100_000)
    dklen = 48
    block_count = ceil(Int, dklen / 32)  # SHA1 outputs 20 bytes
    output = UInt8[]
    for i in 1:block_count
        block_index = reinterpret(UInt8, [hton(Int32(i))])  # 4-byte big-endian
        ctx = HMAC_CTX(SHA256_CTX(), password)
        update!(ctx, salt)
        update!(ctx, block_index)
        u = digest!(ctx)
        t = copy(u)
        for _ = 2:iters
            u = hmac_sha256(password, u)
            for j in 1:length(u)
                t[j] ⊻= u[j]
            end
        end
        append!(output, t)
    end
    key = output[1:32]
    iv = output[33:48]
    return key, iv
end

const SALTED = "Salted__"

function encrypt(password::String, plaintext::String, salt=rand(UInt8, 8))
    key, iv = derive_key_and_iv(Vector{UInt8}(password), salt)
    GC.@preserve salt key iv plaintext begin
        keyr = Ref(aws_byte_cursor_from_array(pointer(key), sizeof(key)))
        ivr = Ref(aws_byte_cursor_from_array(pointer(iv), sizeof(iv)))
        cipher = aws_aes_cbc_256_new(default_aws_allocator(), keyr, ivr)
        @assert cipher != C_NULL "key: $(Vector{UInt8}(key)) iv: $(Vector{UInt8}(iv))"
        try
            encrypted_buf = Ref(aws_byte_buf(0, C_NULL, 0, C_NULL))
            aws_byte_buf_init(encrypted_buf, default_aws_allocator(), sizeof(plaintext) + AWS_AES_256_CIPHER_BLOCK_SIZE)
            try
                @assert (aws_symmetric_cipher_encrypt(cipher, aws_byte_cursor_from_array(pointer(plaintext), sizeof(plaintext)), encrypted_buf) == 0) unsafe_string(aws_error_str(aws_last_error()))
                @assert (aws_symmetric_cipher_finalize_encryption(cipher, encrypted_buf) == 0) unsafe_string(aws_error_str(aws_last_error()))
                bc = aws_byte_cursor_from_buf(encrypted_buf)
                full = Vector{UInt8}(undef, 8 + 8 + bc.len)
                # prepend "Salted__" + salt
                unsafe_copyto!(pointer(full), pointer(SALTED), 8)
                unsafe_copyto!(pointer(full, 9), pointer(salt), 8)
                unsafe_copyto!(pointer(full, 17), bc.ptr, bc.len)
                return "ENC($(base64encode(full)))"
            finally
                aws_byte_buf_clean_up(encrypted_buf)
            end
        finally
            aws_symmetric_cipher_destroy(cipher)
        end
    end
end

str(bc::aws_byte_cursor) = bc.ptr == C_NULL || bc.len == 0 ? "" : unsafe_string(bc.ptr, bc.len)

function decrypt(password::String, enc::String)
    @assert startswith(enc, "ENC(") && endswith(enc, ")")
    raw = base64decode(enc[5:end-1])
    @assert raw[1:8] == codeunits("Salted__") String(raw[1:8])
    salt = raw[9:16]
    ciphertext = String(raw[17:end])
    key, iv = derive_key_and_iv(Vector{UInt8}(password), salt)
    GC.@preserve key iv ciphertext begin
        keyr = Ref(aws_byte_cursor_from_array(pointer(key), sizeof(key)))
        ivr = Ref(aws_byte_cursor_from_array(pointer(iv), sizeof(iv)))
        cipher = aws_aes_cbc_256_new(default_aws_allocator(), keyr, ivr)
        @assert cipher != C_NULL unsafe_string(aws_error_str(aws_last_error()))
        try
            decrypted_buf = Ref(aws_byte_buf(0, C_NULL, 0, C_NULL))
            aws_byte_buf_init(decrypted_buf, default_aws_allocator(), sizeof(ciphertext) + AWS_AES_256_CIPHER_BLOCK_SIZE)
            try
                @assert (aws_symmetric_cipher_decrypt(cipher, aws_byte_cursor_from_array(pointer(ciphertext), sizeof(ciphertext)), decrypted_buf) == 0) unsafe_string(aws_error_str(aws_last_error()))
                @assert (aws_symmetric_cipher_get_state(cipher) == AWS_SYMMETRIC_CIPHER_READY)
                @assert (aws_symmetric_cipher_finalize_decryption(cipher, decrypted_buf) == 0) unsafe_string(aws_error_str(aws_last_error()))
                @assert (aws_symmetric_cipher_get_state(cipher) == AWS_SYMMETRIC_CIPHER_FINALIZED)
                return str(aws_byte_cursor_from_buf(decrypted_buf))
            finally
                aws_byte_buf_clean_up(decrypted_buf)
            end
        finally
            aws_symmetric_cipher_destroy(cipher)
        end
    end
end

end # module