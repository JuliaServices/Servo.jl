using Test
using Servo.MiniHMAC, Servo

@testset "MiniHMAC Token Generation and Verification" begin
    # Setup test configuration
    configs = Dict(
        "hmac" => Dict(
            "signing" => Dict(
                "key" => "my-current-secret-key-32-bytes-long!!",
                "key2" => "my-old-secret-key-32-bytes-long!!"
            )
        )
    )
    # Initialize Servo with test config
    Servo.init(configs=configs)
    @testset "Token Generation" begin
        # Test basic token generation
        payload = TokenPayload("user123", time(), time() + 3600)
        token = generate_token(payload)
        @test !isempty(token)
        @test occursin(".", token)
        # Test convenience function
        convenience_token = generate_token("user456")
        @test !isempty(convenience_token)
        @test occursin(".", convenience_token)
        # Test with custom timestamps
        custom_token = generate_token("user789", issued_at=trunc(Int64, time()), exp=trunc(Int64, time() + 7200))
        @test !isempty(custom_token)
    end
    @testset "Token Verification" begin
        # Test valid token verification
        payload = TokenPayload("user123", time(), time() + 3600)
        token = generate_token(payload)
        verified_payload = verify_token(token)
        @test verified_payload.user_id == "user123"
        @test verified_payload.issued_at == payload.issued_at
        @test verified_payload.exp == payload.exp
        # Test convenience function verification
        convenience_token = generate_token("user456")
        verified_convenience = verify_token(convenience_token)
        @test verified_convenience.user_id == "user456"
    end
    @testset "Expiration Checking" begin
        # Test non-expired token
        payload = TokenPayload("user123", time(), time() + 3600)
        @test !is_expired(payload)
        # Test expired token
        expired_payload = TokenPayload("user789", time() - 7200, time() - 3600)
        @test is_expired(expired_payload)
        # Test expired token verification
        expired_token = generate_token(expired_payload)
        @test_throws ArgumentError verify_token(expired_token)
    end
    @testset "Invalid Tokens" begin
        # Test malformed token
        @test_throws ArgumentError verify_token("invalid.token")
        @test_throws ArgumentError verify_token("not-a-token")
        @test_throws ArgumentError verify_token("part1.part2.part3")
        # Test tampered token
        valid_payload = TokenPayload("user123", time(), time() + 3600)
        valid_token = generate_token(valid_payload)
        tampered_token = valid_token[1:end-5] * "XXXXX"
        @test_throws ArgumentError verify_token(tampered_token)
        # Test token with invalid payload format
        invalid_payload_str = "user123:invalid:timestamp"
        invalid_payload_bytes = Vector{UInt8}(invalid_payload_str)
        encoded_invalid_payload = Servo.MiniHMAC.base64url_encode(invalid_payload_bytes)
        invalid_token = "$(encoded_invalid_payload).dummy_signature"
        @test_throws ArgumentError verify_token(invalid_token)
    end
    @testset "Key Rotation" begin
        # Generate token with current key
        original_payload = TokenPayload("user123", time(), time() + 3600)
        original_token = generate_token(original_payload)
        # Simulate key rotation by updating config
        rotated_configs = Dict(
            "hmac" => Dict(
                "signing" => Dict(
                    "key" => "new-secret-key-32-bytes-long!!",
                    "key2" => "my-current-secret-key-32-bytes-long!!"
                )
            )
        )
        # Reinitialize with rotated config
        Servo.init(configs=rotated_configs)
        # Test new token with new key
        new_payload = TokenPayload("user999", time(), time() + 3600)
        new_token = generate_token(new_payload)
        verified_new = verify_token(new_token)
        @test verified_new.user_id == "user999"
        # Test old token with secondary key (should still work)
        verified_old = verify_token(original_token)
        @test verified_old.user_id == "user123"
    end
end
