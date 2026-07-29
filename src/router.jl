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
# same route shape: literal segments equal, and non-literal segments of the same
# match class in the same positions. Names don't matter — `/users/{id}`,
# `/users/{uid}`, and `/users/*` all match exactly the same requests, as do
# `/files/**` and `/files/{rest...}`.
shapeclass(s::Segment) = s.kind === :literal ? s.text : s.kind === :catchall ? "**" : "*"
sameshape(a::Vector{Segment}, b::Vector{Segment}) = length(a) == length(b) &&
    all(shapeclass(x) == shapeclass(y) for (x, y) in zip(a, b))

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

"""
    Servo.register!([router], method, path, handler; auth, name="", format=TextFormat())

Raw-handler registration — the escape hatch (and the `HTTP.Router` migration
path) for routes that don't fit the endpoint model: static/file serving, proxies,
protocol facades (OAuth callbacks, MCP), etc. `handler` is called as
`handler(request)` with the raw transport request (e.g. an `HTTP.Request`) and
may return a [`Servo.Response`](@ref), `nothing` (204), or any other value
(serialized with `format`, 200). Throw [`HTTPError`](@ref) for error statuses.

No argument binding is performed; path parameters captured by the route pattern
are available inside the handler via [`Servo.pathparams()`](@ref). The full path
grammar applies (`{name}`, `*`, `{name...}`, `**`), and `method` may be a Symbol
or a String.

The auth contract is *not* an escape hatch: raw routes still declare `auth`
explicitly (`auth=Servo.Public()` gets the default rate limiting under `run!`,
like any public endpoint).
"""
# the `where {F}` forces specialization on the handler (bare `::Function` args
# de-specialize), and RawFn carries that concrete type through the kwargs
function register!(r::Router, method::Union{Symbol, AbstractString}, path::AbstractString, handler::F;
                   auth=nothing, name::AbstractString="", format::Format=TextFormat()) where {F}
    m = method isa Symbol ? method : Symbol(uppercase(String(method)))
    # introspection-only params: a raw route still advertises what it captures
    params = Param[Param(s, String, :path) for s in placeholdersyms(parsepattern(path))]
    return register!(r, Endpoint(; method=m, path, target=handler, params,
                                   rawhandler=RawFn(handler), auth, name, format))
end
register!(method::Union{Symbol, AbstractString}, path::AbstractString, handler; kw...) =
    register!(ROUTER, method, path, handler; kw...)

# "/a/b%20c/" -> ["a", "b%20c"]; transports are responsible for any unescaping
splitsegments(path::AbstractString) = String[String(s) for s in split(path, '/'; keepempty=false)]

"""
    Servo.matchroute(router, method, path_or_segments)
        -> (endpoint, pathparams::Dict{Symbol,String}) | :method_not_allowed | nothing

Find the endpoint matching the request. Returns `nothing` when no pattern matches
the path (404) and `:method_not_allowed` when a pattern matches the path but not
this method (405).

**Specificity** (which endpoint wins when several patterns match) is defined, not
emergent: compare the two patterns segment by segment from the left, ranking
literal > single-segment match (`{name}`/`*`) > catch-all (`{name...}`/`**`); the
first position that differs decides, and a full tie goes to the earlier-registered
endpoint. So `/users/me` beats `/users/{id}`, `/a/{x}/c` beats `/{y}/b/c`, and
any fixed-length pattern beats a catch-all where they overlap.
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
    bestsegs = nothing
    pathmatched = false
    for ep in endpoints
        params = matchsegments(ep.segments, segs)
        params === nothing && continue
        if ep.method != method
            pathmatched = true
            continue
        end
        if best === nothing || morespecific(ep.segments, bestsegs::Vector{Segment})
            best = (ep, params)
            bestsegs = ep.segments
        end
    end
    best !== nothing && return best
    return pathmatched ? :method_not_allowed : nothing
end

function matchsegments(pattern::Vector{Segment}, segs::AbstractVector{<:AbstractString})
    n = length(pattern)
    if !isempty(pattern) && last(pattern).kind === :catchall
        length(segs) >= n || return nothing   # a catch-all consumes at least one segment
    else
        length(segs) == n || return nothing
    end
    params = Dict{Symbol, String}()
    for i in 1:n
        p = pattern[i]
        if p.kind === :literal
            p.text == segs[i] || return nothing
        elseif p.kind === :capture
            params[p.sym] = String(segs[i])
        elseif p.kind === :catchall
            isempty(p.text) || (params[p.sym] = join(view(segs, i:length(segs)), '/'))
        end # :wildcard matches anything, binds nothing
    end
    return params
end

# specificity rank of one segment: literal > capture/wildcard > catch-all
segrank(s::Segment) = s.kind === :literal ? 2 : s.kind === :catchall ? 0 : 1

# `a` is more specific than `b`, both having matched the same path: leftmost
# rank difference decides (positions past a catch-all-terminated pattern rank 0)
function morespecific(a::Vector{Segment}, b::Vector{Segment})
    for i in 1:max(length(a), length(b))
        ra = i <= length(a) ? segrank(a[i]) : 0
        rb = i <= length(b) ? segrank(b[i]) : 0
        ra == rb || return ra > rb
    end
    return false
end
