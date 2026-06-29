module Crypt

using LibAwsCommon, LibAwsCal, Random, SHA, Base64

export encrypt, decrypt, jasypt_encrypt, jasypt_decrypt

function __init__()
    # aws-c-cal must be initialized before the symmetric cipher is used on some
    # platforms (notably Linux, where it wires up the libcrypto backend).
    aws_cal_library_init(default_aws_allocator())
end

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

# ----------------------------------------------------------------------------
# Jasypt-compatible AES-256-CBC interop (`PBEWITHHMACSHA512ANDAES_256`).
#
# Byte-for-byte compatible with Java Jasypt 1.9.x configured with
# RandomSaltGenerator + RandomIvGenerator (the common jasypt-spring-boot setup).
#
# Wire format:   base64( salt[16] || iv[16] || AES-256-CBC/PKCS5(plaintext) )
# Key:           PBKDF2-HMAC-SHA512( UTF8(NFC(password)), salt, iterations, 32 )
# IV:            random, 16 bytes, independent of the key
# Plaintext:     UTF-8
# ----------------------------------------------------------------------------

const JASYPT_SALT_SIZE = 16
const JASYPT_IV_SIZE = 16
const JASYPT_DEFAULT_ITERATIONS = 50_000

# HMAC-SHA512 over a single message (fresh context per call, as PBKDF2 re-keys each round).
function _hmac_sha512(key::Vector{UInt8}, msg::Vector{UInt8})
    ctx = HMAC_CTX(SHA512_CTX(), key)
    update!(ctx, msg)
    return digest!(ctx)
end

"""
    pbkdf2_hmac_sha512(password, salt, iterations, dklen) -> Vector{UInt8}

PBKDF2 (RFC 8018) using HMAC-SHA512 as the pseudo-random function.
"""
function pbkdf2_hmac_sha512(password::AbstractVector{UInt8}, salt::AbstractVector{UInt8}, iterations::Integer, dklen::Integer)
    iterations >= 1 || throw(ArgumentError("iterations must be >= 1"))
    dklen >= 1 || throw(ArgumentError("dklen must be >= 1"))
    password = Vector{UInt8}(password)
    salt = Vector{UInt8}(salt)
    hlen = 64  # SHA-512 digest length
    nblocks = cld(dklen, hlen)
    out = Vector{UInt8}(undef, nblocks * hlen)
    block = Vector{UInt8}(undef, 4)
    for i in 1:nblocks
        block[1] = (i >> 24) % UInt8        # INT_32_BE(i)
        block[2] = (i >> 16) % UInt8
        block[3] = (i >> 8) % UInt8
        block[4] = i % UInt8
        ctx = HMAC_CTX(SHA512_CTX(), password)
        update!(ctx, salt)
        update!(ctx, block)
        u = digest!(ctx)                    # U_1 = PRF(P, salt || INT(i))
        t = copy(u)
        for _ in 2:iterations
            u = _hmac_sha512(password, u)   # U_n = PRF(P, U_{n-1})
            @inbounds for j in 1:hlen
                t[j] ⊻= u[j]
            end
        end
        copyto!(out, (i - 1) * hlen + 1, t, 1, hlen)
    end
    return out[1:dklen]
end

# Run aws-c-cal AES-256-CBC over `data`. Throws on cipher failure (incl. bad PKCS5 padding,
# which is what a wrong key produces on decrypt with overwhelming probability).
function _aes_cbc_256(key::Vector{UInt8}, iv::Vector{UInt8}, data::Vector{UInt8}, decrypting::Bool)
    length(key) == 32 || throw(ArgumentError("AES-256 key must be 32 bytes, got $(length(key))"))
    length(iv) == JASYPT_IV_SIZE || throw(ArgumentError("IV must be $JASYPT_IV_SIZE bytes, got $(length(iv))"))
    alloc = default_aws_allocator()
    GC.@preserve key iv data begin
        keyr = Ref(aws_byte_cursor_from_array(pointer(key), sizeof(key)))
        ivr = Ref(aws_byte_cursor_from_array(pointer(iv), sizeof(iv)))
        cipher = aws_aes_cbc_256_new(alloc, keyr, ivr)
        cipher == C_NULL && error("aws_aes_cbc_256_new failed: " * unsafe_string(aws_error_str(aws_last_error())))
        try
            outbuf = Ref(aws_byte_buf(0, C_NULL, 0, C_NULL))
            aws_byte_buf_init(outbuf, alloc, length(data) + AWS_AES_256_CIPHER_BLOCK_SIZE)
            try
                incur = aws_byte_cursor_from_array(pointer(data), sizeof(data))
                if decrypting
                    aws_symmetric_cipher_decrypt(cipher, incur, outbuf) == 0 ||
                        error("AES-CBC decrypt failed: " * unsafe_string(aws_error_str(aws_last_error())))
                    aws_symmetric_cipher_finalize_decryption(cipher, outbuf) == 0 ||
                        error("AES-CBC decrypt finalize failed (wrong key or corrupt ciphertext): " * unsafe_string(aws_error_str(aws_last_error())))
                else
                    aws_symmetric_cipher_encrypt(cipher, incur, outbuf) == 0 ||
                        error("AES-CBC encrypt failed: " * unsafe_string(aws_error_str(aws_last_error())))
                    aws_symmetric_cipher_finalize_encryption(cipher, outbuf) == 0 ||
                        error("AES-CBC encrypt finalize failed: " * unsafe_string(aws_error_str(aws_last_error())))
                end
                bc = aws_byte_cursor_from_buf(outbuf)
                result = Vector{UInt8}(undef, bc.len)
                bc.len > 0 && GC.@preserve result unsafe_copyto!(pointer(result), bc.ptr, bc.len)
                return result
            finally
                aws_byte_buf_clean_up(outbuf)
            end
        finally
            aws_symmetric_cipher_destroy(cipher)
        end
    end
end

# password -> key-derivation bytes, exactly as Jasypt/SunJCE: UTF-8 of the NFC-normalized password.
_jasypt_password_bytes(password::AbstractString) = Vector{UInt8}(Base.Unicode.normalize(String(password), :NFC))

"""
    jasypt_decrypt(password, enc; iterations=50000) -> String

Decrypt a value produced by Java Jasypt's `PBEWITHHMACSHA512ANDAES_256`
(random salt + IV). `enc` may be bare Base64 or wrapped as `ENC(...)`.
Throws if the password is wrong or the ciphertext is corrupt.
"""
function jasypt_decrypt(password::AbstractString, enc::AbstractString; iterations::Integer=JASYPT_DEFAULT_ITERATIONS)
    s = String(enc)
    if startswith(s, "ENC(") && endswith(s, ")")
        s = s[5:prevind(s, lastindex(s))]
    end
    raw = base64decode(s)
    minlen = JASYPT_SALT_SIZE + JASYPT_IV_SIZE + AWS_AES_256_CIPHER_BLOCK_SIZE
    length(raw) >= minlen || throw(ArgumentError("ciphertext too short ($(length(raw)) bytes; need >= $minlen)"))
    salt = raw[1:JASYPT_SALT_SIZE]
    iv = raw[JASYPT_SALT_SIZE+1:JASYPT_SALT_SIZE+JASYPT_IV_SIZE]
    ct = raw[JASYPT_SALT_SIZE+JASYPT_IV_SIZE+1:end]
    key = pbkdf2_hmac_sha512(_jasypt_password_bytes(password), salt, iterations, 32)
    return String(_aes_cbc_256(key, iv, ct, true))
end

"""
    jasypt_encrypt(password, plaintext; iterations=50000, salt=rand(16), iv=rand(16)) -> String

Encrypt `plaintext` in Jasypt `PBEWITHHMACSHA512ANDAES_256` format, returning the bare
Base64 string (Jasypt's native output — wrap in `ENC(...)` yourself for jasypt-spring-boot
config files). `salt`/`iv` are exposed so callers can reproduce deterministic vectors.
"""
function jasypt_encrypt(password::AbstractString, plaintext::AbstractString;
                        iterations::Integer=JASYPT_DEFAULT_ITERATIONS,
                        salt::Vector{UInt8}=rand(UInt8, JASYPT_SALT_SIZE),
                        iv::Vector{UInt8}=rand(UInt8, JASYPT_IV_SIZE))
    length(salt) == JASYPT_SALT_SIZE || throw(ArgumentError("salt must be $JASYPT_SALT_SIZE bytes"))
    length(iv) == JASYPT_IV_SIZE || throw(ArgumentError("iv must be $JASYPT_IV_SIZE bytes"))
    key = pbkdf2_hmac_sha512(_jasypt_password_bytes(password), salt, iterations, 32)
    ct = _aes_cbc_256(key, iv, Vector{UInt8}(String(plaintext)), false)
    return base64encode(vcat(salt, iv, ct))
end

end # module