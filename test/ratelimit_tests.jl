@testset "Rate-limit refill and cleanup" begin
    at(rl, key, now) = lock(rl.lock) do
        Servo._allow!(rl, key, Float64(now))
    end
    key = ("endpoint", "client")
    for bad in (-1.0, Inf, -Inf, NaN)
        @test_throws ArgumentError Servo.RateLimiter(; rps=bad)
        @test_throws ArgumentError Servo.RateLimiter(; burst=bad)
    end
    for capacity in (0.0, 0.5)
        rl = Servo.RateLimiter(; burst=capacity)
        @test !Servo.allow!(rl, key)
        @test isempty(rl.buckets)
    end

    rl = Servo.RateLimiter(; rps=2.0, burst=2.0)
    @test at(rl, key, 100)
    @test at(rl, key, 100)
    @test !at(rl, key, 100)
    @test !at(rl, key, 100.25)
    @test at(rl, key, 100.5)
    @test at(rl, ("endpoint", "other"), 100.5)
    @test at(rl, key, 1.0e12)
    @test rl.buckets[key].tokens == 1.0

    # Zero-refill buckets cannot expire: forgetting one would restore its burst.
    rl = Servo.RateLimiter(; rps=0.0, burst=2.0)
    for i in 1:8193
        rl.buckets[("endpoint", string(i))] = Servo.TokenBucket(0.0, 100.0)
    end
    @test !at(rl, ("endpoint", "1"), 1.0e12)
    @test length(rl.buckets) == 8193

    # Cleanup may retain expired entries until the next interval, but must not
    # reset active clients' balances when removing their idle neighbors.
    rl = Servo.RateLimiter(; rps=2.0, burst=4.0)
    for i in 1:8193
        rl.buckets[("endpoint", string(i))] = Servo.TokenBucket(4.0, 100.0)
    end
    key = ("endpoint", "1")
    @test at(rl, key, 100)
    @test length(rl.buckets) == 8193
    rl.buckets[("endpoint", "2")].last = 50.0
    for _ in 1:4
        @test at(rl, key, 101.9)
    end
    @test !at(rl, key, 101.9)
    @test length(rl.buckets) == 8193
    @test !at(rl, key, 102)
    @test length(rl.buckets) == 1
    @test rl.buckets[key].tokens ≈ 0.2
    @test at(rl, key, 104)
    @test rl.buckets[key].tokens == 3.0

    # All tasks compete for one initial burst; elapsed test time adds no tokens.
    rl = Servo.RateLimiter(; rps=0.0, burst=64.0)
    start = Base.Event()
    tasks = Task[]
    for _ in 1:256
        push!(tasks, Threads.@spawn begin
            wait(start)
            Servo.allow!(rl, key)
        end)
    end
    notify(start)
    @test count(identity, fetch.(tasks)) == 64
    @test !Servo.allow!(rl, key)
end
