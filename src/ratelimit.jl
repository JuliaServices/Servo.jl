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
    buckets::Dict{Tuple{String, String}, TokenBucket}
    lock::ReentrantLock
end
RateLimiter(; rps::Real=5.0, burst::Real=20.0) =
    RateLimiter(Float64(rps), Float64(burst), Dict{Tuple{String, String}, TokenBucket}(), ReentrantLock())

"""
    Servo.allow!(limiter, (name, client)) -> Bool

Spend one token from the bucket for the `(name, client)` string pair if available.
"""
function allow!(rl::RateLimiter, key::Tuple{String, String})
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

function checkratelimit!(ep::Endpoint, client)
    rl = PUBLIC_RATE_LIMITER[]
    rl === nothing && return
    c = client === nothing ? "" : client isa String ? client : string(client)
    allow!(rl, (ep.name, c)) || throw(HTTPError(429, "rate limit exceeded"))
    return
end
