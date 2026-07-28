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
"""
struct RateLimiter
    rps::Float64
    burst::Float64
    buckets::Dict{Any, TokenBucket}
    lock::ReentrantLock
end
RateLimiter(; rps::Real=5.0, burst::Real=20.0) =
    RateLimiter(Float64(rps), Float64(burst), Dict{Any, TokenBucket}(), ReentrantLock())

"""
    Servo.allow!(limiter, key) -> Bool

Spend one token from `key`'s bucket if available.
"""
function allow!(rl::RateLimiter, key)
    now = time()
    lock(rl.lock) do
        # bound memory: drop buckets idle long enough to be full again
        length(rl.buckets) > 8192 &&
            filter!(kv -> now - kv.second.last < rl.burst / rl.rps, rl.buckets)
        b = get!(() -> TokenBucket(rl.burst, now), rl.buckets, key)
        b.tokens = min(rl.burst, b.tokens + (now - b.last) * rl.rps)
        b.last = now
        b.tokens >= 1.0 || return false
        b.tokens -= 1.0
        return true
    end
end

# set by `run!`; nothing disables public rate limiting (e.g. bare `serve!` in tests)
const PUBLIC_RATE_LIMITER = Ref{Union{RateLimiter, Nothing}}(nothing)

function checkratelimit!(ep::Endpoint, key)
    rl = PUBLIC_RATE_LIMITER[]
    rl === nothing && return
    allow!(rl, (ep.name, key)) || throw(HTTPError(429, "rate limit exceeded"))
    return
end
