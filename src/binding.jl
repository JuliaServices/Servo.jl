# ── transport interface ─────────────────────────────────────────────────────
# A transport teaches Servo how to read its request type by implementing these
# three accessors; everything else (binding, coercion, auth, dispatch) is generic.

"""
    Servo.rawbody(request) -> AbstractVector{UInt8} | AbstractString | nothing

The raw request payload, or `nothing`/empty when the request has none. Implemented
by each transport for its concrete request type.
"""
function rawbody end

"""
    Servo.rawquery(request) -> iterable of String => String pairs

The request's query/request parameters as key => value string pairs (repeated keys
allowed; the first occurrence wins). Implemented by each transport.
"""
function rawquery end

"""
    Servo.clientip(request)

Best-effort client address used to key public-endpoint rate limiting. Defaults to
`nothing`, which pools all clients into a single bucket.
"""
clientip(request) = nothing

"""
    Servo.Response(status, body=""; headers=[])

Transport-neutral response a handler may return to control status and headers.
`body` must already be serialized (a string or bytes). Handlers that return any
other value get automatic serialization via the endpoint's `Format` and a 200
(or 204 for `nothing`).
"""
struct Response
    status::Int
    headers::Vector{Pair{String, String}}
    body::Union{String, Vector{UInt8}}
end
Response(status::Integer, body::Union{AbstractString, AbstractVector{UInt8}}=UInt8[];
         headers::AbstractVector=Pair{String, String}[]) =
    Response(status, convert(Vector{Pair{String, String}}, headers),
             body isa AbstractString ? String(body) : Vector{UInt8}(body))

# ── request handling ────────────────────────────────────────────────────────

"""
    Servo.handle(endpoint, pathparams, request) -> Servo.Response

The generic request pipeline entrypoint, shared by all transports. Extracts the
query pairs, body bytes, and client address from the (concretely typed) transport
request, then invokes the endpoint's type-erased handler, which authenticates
(or rate-limits a public endpoint), binds the target function's arguments, and
packages the result. Throws `HTTPError` for all request-level failures;
transports translate that into their wire format.
"""
function handle(ep::Endpoint, pathparams::AbstractDict{Symbol, <:AbstractString}, req)
    pp = pathparams isa Dict{Symbol, String} ? pathparams :
        Dict{Symbol, String}(k => String(v) for (k, v) in pathparams)
    query = Dict{String, String}()
    for (k, v) in rawquery(req)
        haskey(query, k) || (query[String(k)] = String(v))
    end
    raw = rawbody(req)
    body = raw === nothing ? UInt8[] :
        raw isa Vector{UInt8} ? raw :
        raw isa AbstractVector{UInt8} ? Vector{UInt8}(raw) :
        Vector{UInt8}(codeunits(String(raw)))
    ip = clientip(req)
    ipstr = ip === nothing ? "" : ip isa String ? ip : string(ip)
    return ep.handler(pp, query, body, ipstr, req)
end

"""
The per-endpoint request pipeline, wrapped in a [`HandlerFn`](@ref) at endpoint
construction: auth (or public rate limiting), ambient request context, argument
binding via the endpoint's binder, and result packaging — all statically
compiled against the endpoint's concrete binder/auth/format types.
"""
struct RequestHandler{B, A <: AuthScheme, S <: Format} <: Function
    name::String
    binder::B
    auth::A
    format::S
end

# ── static request-scope construction ───────────────────────────────────────
# `@with PRINCIPAL => pr REQUEST => call.req ...` builds each entry with
# `=>`, and `Pair(a, b)` computes `typeof(b)` at runtime — for the `Any`-typed
# request slot that is a dynamic call the trim verifier cannot resolve. These
# helpers build the same `Scope` through `KeyValue.set` (no `Pair` at all) and
# enter it with the same lowered `:tryfinally` scope form the macro uses, so
# scoped-value semantics (including propagation to spawned tasks) are
# unchanged while every call stays statically dispatched.
# `@nospecialize(value)` prevents the caller from emitting a runtime-
# specializing dispatch for the `Any`-typed request slot. The insert calls
# `Base._keyvalueset` directly: the `KeyValue.set` wrappers add a second
# applicable method at this call type, and the patched-Julia trim toolchain
# despecializes `_keyvalueset`'s value parameter to match.
function scopewith(parent::Union{Nothing, Base.ScopedValues.Scope},
                   key::Base.ScopedValues.ScopedValue{T}, @nospecialize(value)) where {T}
    val = convert(T, value)
    storage = parent === nothing ?
        Base.KeyValue.set(Base.ScopedValues.ScopeStorage, nothing, key, val) :
        Base._keyvalueset(parent.values, key, val)
    return Base.ScopedValues.Scope(storage)
end

function requestscope(pr, call::HandlerCall)
    scope = scopewith(Core.current_scope()::Union{Nothing, Base.ScopedValues.Scope}, PRINCIPAL, pr)
    scope = scopewith(scope, REQUEST, call.req)
    return scopewith(scope, PATHPARAMS, call.pathparams)
end

macro inscope(scope, body)
    return Expr(:tryfinally, esc(body), nothing, esc(scope))
end

function (h::RequestHandler)(call::HandlerCall)
    pr = checkauth(h.name, h.auth, call)
    scope = requestscope(pr, call)
    return @inscope scope begin
        toresponse(h.format, h.binder(h.format, call.pathparams, call.query, call.body))
    end
end

"""
The pipeline for raw-handler routes (see `Servo.register!(router, method, path,
handler; ...)`): same auth/rate-limit gate and ambient request context as bound
endpoints, but the handler receives the raw transport request and does its own
request reading — no argument binding. Path parameters captured by the route
pattern are available via `Servo.pathparams()`.
"""
struct RawHandler{F, A <: AuthScheme, S <: Format} <: Function
    name::String
    f::F
    auth::A
    format::S
end

function (h::RawHandler)(call::HandlerCall)
    pr = checkauth(h.name, h.auth, call)
    scope = requestscope(pr, call)
    return @inscope scope begin
        toresponse(h.format, h.f.f(call.req))
    end
end

# the shared gate: authenticate, or rate-limit an explicitly-Public route
function checkauth(name::String, auth::AuthScheme, call::HandlerCall)
    if auth isa Public
        checkratelimit!(name, call.clientip)
        return nothing
    end
    pr = authenticate(auth, call.req)
    pr === nothing && throw(HTTPError(401, "unauthorized"))
    return pr
end

toresponse(::Format, r::Response) = r
toresponse(::Format, ::Nothing) = Response(204)
toresponse(fmt::Format, result) =
    Response(200, serialize(fmt, result); headers=["Content-Type" => mime(fmt)])

# ── statically-typed binding helpers ────────────────────────────────────────
# The endpoint macros generate a binder `(format, pathparams, query, body) ->
# result` whose body calls these with the parameter types as literal `Type`
# arguments, so every call is statically dispatched (juliac/trim friendly) and
# the binding order follows the function signature (later keyword defaults may
# reference earlier arguments, as in a normal Julia call).

hasquery(q::Dict{String, String}, name::String) = haskey(q, name)

# return annotations keep binders fully inferable (so e.g. response types can be
# derived from a binder's return type)
function pathvalue(::Type{T}, pathparams::Dict{Symbol, String}, name::Symbol)::T where {T}
    return coerceparam(T, pathparams[name], name)
end

function queryvalue(::Type{T}, q::Dict{String, String}, name::Symbol)::T where {T}
    raw = get(q, String(name), nothing)
    raw === nothing && throw(HTTPError(400, "missing required query parameter `$name`"))
    return coerceparam(T, raw, name)
end

function bodyvalue(fmt::Format, ::Type{T}, body::Vector{UInt8}, name::Symbol)::T where {T}
    isempty(body) && throw(HTTPError(400, "request body required for `$name`"))
    try
        return deserialize(fmt, T, body)
    catch e
        e isa HTTPError && rethrow()
        throw(HTTPError(400, "malformed request body for `$name`"))
    end
end

# ── the reflective fallback binder ──────────────────────────────────────────

function (b::GenericBinder)(fmt::Format, pathparams, query, body)
    args, kwargs = bind(b.params, fmt, pathparams, query, body)
    return b.target(args...; kwargs...)
end

"""
    Servo.bind(params, format, pathparams, query, body) -> (args, kwargs)

Reflectively extract and coerce a target function's arguments: path parameters
(from the router match) and the request body in positional order, query
parameters as keyword arguments. Absent optional query parameters are simply not
passed, so the function's own defaults apply. This is the
[`GenericBinder`](@ref) implementation; macro-registered endpoints use a
generated statically-typed binder instead.
"""
function bind(params::Vector{Param}, fmt::Format, pathparams::Dict{Symbol, String},
              query::Dict{String, String}, body::Vector{UInt8})
    args = Any[]
    kwargs = Pair{Symbol, Any}[]
    for p in params
        if p.source == :path
            push!(args, coerceparam(p.type, pathparams[p.name], p.name))
        elseif p.source == :query
            raw = get(query, String(p.name), nothing)
            if raw !== nothing
                push!(kwargs, p.name => coerceparam(p.type, raw, p.name))
            elseif p.required
                throw(HTTPError(400, "missing required query parameter `$(p.name)`"))
            end
        else # :body
            push!(args, bodyvalue(fmt, p.type, body, p.name))
        end
    end
    return args, kwargs
end

# ── string -> typed value coercion for path/query parameters ────────────────

function coerceparam(::Type{T}, raw::AbstractString, name::Symbol) where {T}
    try
        return coerce(T, raw)
    catch e
        e isa HTTPError && rethrow()
        throw(HTTPError(400, "invalid value \"$raw\" for parameter `$name`: expected $T"))
    end
end

nonnothing(::Type{T}) where {T} = T isa Union ?
    (T.a === Nothing ? T.b : T.b === Nothing ? T.a : T) : T

coerce(::Type{Any}, raw::AbstractString) = String(raw)
coerce(::Type{T}, raw::AbstractString) where {T <: AbstractString} = convert(T, String(raw))
coerce(::Type{Bool}, raw::AbstractString) =
    raw in ("1", "t", "T", "true", "True", "TRUE") ? true :
    raw in ("0", "f", "F", "false", "False", "FALSE") ? false :
    throw(ArgumentError("invalid Bool: $raw"))
coerce(::Type{T}, raw::AbstractString) where {T <: Number} = parse(T, raw)
coerce(::Type{T}, raw::AbstractString) where {E, T <: AbstractVector{E}} =
    convert(T, E[coerce(E, x) for x in split(raw, ',')])
function coerce(::Type{T}, raw::AbstractString) where {T}
    if T isa Union && Nothing <: T
        return isempty(raw) ? nothing : coerce(nonnothing(T), raw)
    end
    # anything that knows how to parse itself from a string (Dates.Date, UUID, ...)
    hasmethod(parse, Tuple{Type{T}, String}) && return parse(T, String(raw))
    return T(String(raw))
end
