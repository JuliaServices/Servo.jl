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

The generic request pipeline, shared by all transports: authenticate (or
rate-limit a public endpoint), invoke the endpoint's binder (which extracts and
coerces the target function's arguments and calls it), and package the result.
Throws `HTTPError` for all request-level failures; transports translate that into
their wire format.
"""
function handle(ep::Endpoint, pathparams::AbstractDict{Symbol, <:AbstractString}, req)
    if ep.auth isa Public
        checkratelimit!(ep, clientip(req))
        pr = nothing
    else
        pr = authenticate(ep.auth, req)
        pr === nothing && throw(HTTPError(401, "unauthorized"))
    end
    return withcontext(() -> toresponse(ep, ep.binder(ep.format, pathparams, req)), pr, req)
end

toresponse(::Endpoint, r::Response) = r
toresponse(::Endpoint, ::Nothing) = Response(204)
toresponse(ep::Endpoint, result) =
    Response(200, serialize(ep.format, result); headers=["Content-Type" => mime(ep.format)])

# ── statically-typed binding helpers ────────────────────────────────────────
# The endpoint macros generate a binder function whose body calls these with the
# parameter types as literal `Type` arguments, so every call is statically
# dispatched (juliac/trim friendly) and the binding order follows the function
# signature (later keyword defaults may reference earlier arguments, as in a
# normal Julia call).

function querydict(req)
    q = Dict{String, String}()
    for (k, v) in rawquery(req)
        haskey(q, k) || (q[String(k)] = String(v))
    end
    return q
end

hasquery(q::Dict{String, String}, name::String) = haskey(q, name)

# return annotations keep binders fully inferable (so e.g. response types can be
# derived from a binder's return type) even when the request type is abstract
function pathvalue(::Type{T}, pathparams::AbstractDict{Symbol, <:AbstractString}, name::Symbol)::T where {T}
    return coerceparam(T, pathparams[name], name)
end

function queryvalue(::Type{T}, q::Dict{String, String}, name::Symbol)::T where {T}
    raw = get(q, String(name), nothing)
    raw === nothing && throw(HTTPError(400, "missing required query parameter `$name`"))
    return coerceparam(T, raw, name)
end

function bodyvalue(fmt::Format, ::Type{T}, req, name::Symbol)::T where {T}
    body = rawbody(req)
    (body === nothing || isempty(body)) &&
        throw(HTTPError(400, "request body required for `$name`"))
    try
        return deserialize(fmt, T, body)
    catch e
        e isa HTTPError && rethrow()
        throw(HTTPError(400, "malformed request body for `$name`"))
    end
end

# ── the reflective fallback binder ──────────────────────────────────────────

function (b::GenericBinder)(fmt::Format, pathparams, req)
    args, kwargs = bind(b.params, fmt, pathparams, req)
    return b.target(args...; kwargs...)
end

"""
    Servo.bind(params, format, pathparams, request) -> (args, kwargs)

Reflectively extract and coerce a target function's arguments from a transport
request: path parameters (from the router match) and the request body in
positional order, query parameters as keyword arguments. Absent optional query
parameters are simply not passed, so the function's own defaults apply. This is
the [`GenericBinder`](@ref) implementation; macro-registered endpoints use a
generated statically-typed binder instead.
"""
function bind(params::Vector{Param}, fmt::Format, pathparams::AbstractDict{Symbol, <:AbstractString}, req)
    args = Any[]
    kwargs = Pair{Symbol, Any}[]
    query = nothing
    for p in params
        if p.source == :path
            push!(args, coerceparam(p.type, pathparams[p.name], p.name))
        elseif p.source == :query
            query === nothing && (query = querydict(req))
            raw = get(query, String(p.name), nothing)
            if raw !== nothing
                push!(kwargs, p.name => coerceparam(p.type, raw, p.name))
            elseif p.required
                throw(HTTPError(400, "missing required query parameter `$(p.name)`"))
            end
        else # :body
            push!(args, bodyvalue(fmt, p.type, req, p.name))
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
