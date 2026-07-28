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
rate-limit a public endpoint), bind the request to the target function's
arguments, invoke it, and package the result. Throws `HTTPError` for all
request-level failures; transports translate that into their wire format.
"""
function handle(ep::Endpoint, pathparams::AbstractDict{Symbol, <:AbstractString}, req)
    if ep.auth isa Public
        checkratelimit!(ep, clientip(req))
        pr = nothing
    else
        pr = authenticate(ep.auth, req)
        pr === nothing && throw(HTTPError(401, "unauthorized"))
    end
    return @with PRINCIPAL => pr REQUEST => req begin
        args, kwargs = bind(ep, pathparams, req)
        toresponse(ep, ep.target(args...; kwargs...))
    end
end

toresponse(::Endpoint, r::Response) = r
toresponse(::Endpoint, ::Nothing) = Response(204)
toresponse(ep::Endpoint, result) =
    Response(200, serialize(ep.format, result); headers=["Content-Type" => mime(ep.format)])

"""
    Servo.bind(endpoint, pathparams, request) -> (args, kwargs)

Extract and coerce the target function's arguments from a transport request:
path parameters (from the router match) and the request body in positional order,
query parameters as keyword arguments. Absent optional query parameters are
simply not passed, so the function's own defaults apply.
"""
function bind(ep::Endpoint, pathparams::AbstractDict{Symbol, <:AbstractString}, req)
    args = Any[]
    kwargs = Pair{Symbol, Any}[]
    query = nothing
    for p in ep.params
        if p.source == :path
            push!(args, coerceparam(p, pathparams[p.name]))
        elseif p.source == :query
            if query === nothing
                query = Dict{String, String}()
                for (k, v) in rawquery(req)
                    haskey(query, k) || (query[String(k)] = String(v))
                end
            end
            raw = get(query, String(p.name), nothing)
            if raw !== nothing
                push!(kwargs, p.name => coerceparam(p, raw))
            elseif p.required
                throw(HTTPError(400, "missing required query parameter `$(p.name)`"))
            end
        else # :body
            body = rawbody(req)
            (body === nothing || isempty(body)) &&
                throw(HTTPError(400, "request body required for `$(p.name)`"))
            val = try
                deserialize(ep.format, p.type, body)
            catch e
                e isa HTTPError && rethrow()
                throw(HTTPError(400, "malformed request body for `$(p.name)`: $(sprint(showerror, e))"))
            end
            push!(args, val)
        end
    end
    return args, kwargs
end

# ── string -> typed value coercion for path/query parameters ────────────────

function coerceparam(p::Param, raw::AbstractString)
    try
        return coerce(p.type, raw)
    catch e
        e isa HTTPError && rethrow()
        throw(HTTPError(400, "invalid value \"$raw\" for parameter `$(p.name)`: expected $(p.type)"))
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
