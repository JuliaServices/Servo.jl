"""
    Servo.Router()

An ordered, introspectable collection of [`Endpoint`](@ref)s with pure-Julia path
matching. Routers are plain values: construct as many as you like (isolated
routers make endpoints unit-testable) and pass one to `Servo.run!`/`Servo.serve!`.
The `@GET`/`@POST`/… macros default to the global `Servo.ROUTER` for convenience.
"""
struct Router
    endpoints::Vector{Endpoint}
    lock::ReentrantLock
end
Router() = Router(Endpoint[], ReentrantLock())

Base.empty!(r::Router) = (lock(() -> empty!(r.endpoints), r.lock); r)

"""default router used by the endpoint macros and `Servo.run!` when none is given"""
const ROUTER = Router()

"""
    Servo.register!([router], endpoint) -> endpoint

Add an endpoint to a router. Registering a second endpoint with the same method
and path shape replaces the first (with a warning) — convenient for interactive
redefinition.
"""
# same route shape: literal segments equal, captures in the same positions
# (capture *names* don't matter: `/users/{id}` and `/users/{uid}` match the same requests)
sameshape(a, b) = length(a) == length(b) &&
    all(x isa Symbol ? y isa Symbol : x == y for (x, y) in zip(a, b))

function register!(r::Router, ep::Endpoint)
    lock(r.lock) do
        i = findfirst(e -> e.method == ep.method && sameshape(e.segments, ep.segments), r.endpoints)
        if i === nothing
            push!(r.endpoints, ep)
        else
            @warn "replacing already-registered endpoint" method=ep.method path=ep.path
            r.endpoints[i] = ep
        end
    end
    return ep
end
register!(ep::Endpoint) = register!(ROUTER, ep)

# "/a/b%20c/" -> ["a", "b%20c"]; transports are responsible for any unescaping
splitsegments(path::AbstractString) = String[String(s) for s in split(path, '/'; keepempty=false)]

"""
    Servo.matchroute(router, method, path_or_segments)
        -> (endpoint, pathparams::Dict{Symbol,String}) | :method_not_allowed | nothing

Find the endpoint matching the request. When several patterns match a path, the
one with the most literal (non-parameter) segments wins, so `/users/me` beats
`/users/{id}`. Returns `nothing` when no pattern matches the path (404) and
`:method_not_allowed` when a pattern matches but not for this method (405).
"""
matchroute(r::Router, method::AbstractString, path::AbstractString) =
    matchroute(r, Symbol(method), splitsegments(path))

function matchroute(r::Router, method::Symbol, segs::AbstractVector{<:AbstractString})
    # explicit lock/unlock: a `lock() do` closure would box the scan state below
    lock(r.lock)
    try
        return _matchroute(r.endpoints, method, segs)
    finally
        unlock(r.lock)
    end
end

function _matchroute(endpoints::Vector{Endpoint}, method::Symbol, segs::AbstractVector{<:AbstractString})
    best = nothing
    bestscore = -1
    pathmatched = false
    for ep in endpoints
        res = matchsegments(ep.segments, segs)
        res === nothing && continue
        if ep.method != method
            pathmatched = true
            continue
        end
        score, params = res
        if score > bestscore
            best = (ep, params)
            bestscore = score
        end
    end
    best !== nothing && return best
    return pathmatched ? :method_not_allowed : nothing
end

function matchsegments(pattern::Vector{Union{String, Symbol}}, segs::AbstractVector{<:AbstractString})
    length(pattern) == length(segs) || return nothing
    score = 0
    params = Dict{Symbol, String}()
    for (p, s) in zip(pattern, segs)
        if p isa Symbol
            params[p] = String(s)
        else
            p == s || return nothing
            score += 1
        end
    end
    return score, params
end
