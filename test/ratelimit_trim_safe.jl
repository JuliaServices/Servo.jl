# Standalone rate limiting does not need the full server's scoped request
# context. Require this workload to compile and execute without trim findings.
using Servo

function cleanup_count(nkeys::Int)::Int
    rl = Servo.RateLimiter(; rps=2.0, burst=4.0)
    for i in 1:nkeys
        rl.buckets[("endpoint", string(i))] = Servo.TokenBucket(0.0, 100.0)
    end
    key = ("endpoint", "1")
    lock(rl.lock)
    try
        Servo._allow!(rl, key, 100.0) && return -1
        length(rl.buckets) == nkeys || return -1
        Servo._allow!(rl, key, 101.9) || return -1
        Servo._allow!(rl, key, 102.0) || return -1
        1.9 < rl.buckets[key].tokens < 2.1 || return -1
        return length(rl.buckets)
    finally
        unlock(rl.lock)
    end
end

function @main(args::Vector{String})::Cint
    isempty(args) || length(args) == 3 || return 2
    nkeys = isempty(args) ? 8193 : parse(Int, args[1])
    burst = isempty(args) ? 4 : parse(Int, args[2])
    expected = isempty(args) ? 3 : parse(Int, args[3])
    8193 <= nkeys <= 65536 && 1 <= burst <= 20 || return 2
    rl = Servo.RateLimiter(; rps=1.0e-6, burst=Float64(burst))
    for i in 1:nkeys
        Servo.allow!(rl, ("endpoint", string(i))) || return 1
    end
    accepted = 0
    for _ in 1:burst+2
        accepted += Servo.allow!(rl, ("endpoint", "1"))
    end
    return accepted == expected && length(rl.buckets) == nkeys && cleanup_count(nkeys) == 1 ? 0 : 1
end

Base.Experimental.entrypoint(main, (Vector{String},))
