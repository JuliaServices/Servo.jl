mutable struct TokenBucket
    tokens::Float64
    last::Float64
end

"""
    Servo.RateLimiter(; rps=5.0, burst=20.0)

Per-key token-bucket rate limiter: each key accrues `rps` tokens per second up to
`burst`, and each request spends one. `Servo.run!` installs one of these over all
[`Public`](@ref) endpoints, keyed by (endpoint, client IP), configurable via the
`public_ratelimit_rps` / `public_ratelimit_burst` config keys.

Both settings must be finite and nonnegative. A zero rate spends the initial
burst without refilling; a burst below one rejects every request. Refilling uses
a monotonic clock. Above 8,192 keys, idle buckets are removed lazily, at most once
per full-refill interval. Active buckets are retained; this is not a hard key limit.
"""
mutable struct RateLimiter
    const rps::Float64
    const burst::Float64
    const buckets::Dict{Tuple{String, String}, TokenBucket}
    const lock::ReentrantLock
    last_cleanup::Float64
end
function RateLimiter(rps::Real, burst::Real,
                     buckets::Dict{Tuple{String, String}, TokenBucket}, lock::ReentrantLock)
    rate, capacity = Float64(rps), Float64(burst)
    isfinite(rate) && rate >= 0 || throw(ArgumentError("rps must be finite and nonnegative"))
    isfinite(capacity) && capacity >= 0 || throw(ArgumentError("burst must be finite and nonnegative"))
    return RateLimiter(rate, capacity, buckets, lock, -Inf)
end
RateLimiter(; rps::Real=5.0, burst::Real=20.0) =
    RateLimiter(rps, burst, Dict{Tuple{String, String}, TokenBucket}(), ReentrantLock())

"""
    Servo.allow!(limiter, (name, client)) -> Bool

Spend one token from the bucket for the `(name, client)` string pair if available.
"""
function allow!(rl::RateLimiter, key::Tuple{String, String})
    lock(rl.lock) do
        # Sample after acquiring the lock so timestamps follow request order.
        return _allow!(rl, key, Float64(time_ns()) * 1.0e-9)
    end
end

# Caller holds rl.lock; now is monotonic seconds.
function _allow!(rl::RateLimiter, key::Tuple{String, String}, now::Float64)
    rl.burst < 1.0 && return false
    if length(rl.buckets) > 8192 && rl.rps > 0.0
        interval = rl.burst / rl.rps
        if now - rl.last_cleanup >= interval
            # ponytail: periodic O(n) cleanup; use an expiry index if bounded
            # single-request cleanup latency becomes necessary.
            filter!(kv -> now - kv.second.last < interval, rl.buckets)
            rl.last_cleanup = now
        end
    end
    b = get!(() -> TokenBucket(rl.burst, now), rl.buckets, key)
    b.tokens = min(rl.burst, b.tokens + (now - b.last) * rl.rps)
    b.last = now
    b.tokens >= 1.0 || return false
    b.tokens -= 1.0
    return true
end

# set by `run!`; nothing disables public rate limiting (e.g. bare `serve!` in tests)
const PUBLIC_RATE_LIMITER = Ref{Union{RateLimiter, Nothing}}(nothing)

function checkratelimit!(name::String, client::String)
    rl = PUBLIC_RATE_LIMITER[]
    rl === nothing && return
    allow!(rl, (name, client)) || throw(HTTPError(429, "rate limit exceeded"))
    return
end
