# HTTP transport: implements the transport accessor interface for HTTP.Request
# and owns the server lifecycle + HTTP-level middleware (error envelope, CORS,
# access log).

rawbody(req::HTTP.Request) = req.body
rawquery(req::HTTP.Request) = querypairs(last(splittarget(req.target)))

# ── request-target parsing ──────────────────────────────────────────────────
# URIs.jl's general parser (regex capture groups, `unescapeuri`, `decodeplus`)
# is dynamically dispatched internally — unresolvable under juliac --trim. A
# request target is a much smaller grammar than a full URI reference, so the
# server side parses it directly: split on '?', percent-decode per component.

"""split a raw request target into its path and query parts (either may be empty)"""
function splittarget(target::AbstractString)
    q = findfirst(==('?'), target)
    q === nothing && return SubString(target), SubString("")
    return SubString(target, firstindex(target), prevind(target, q)),
           SubString(target, nextind(target, q))
end

_hexval(b::UInt8) =
    UInt8('0') <= b <= UInt8('9') ? b - UInt8('0') :
    UInt8('A') <= b <= UInt8('F') ? b - UInt8('A') + 0x0a :
    UInt8('a') <= b <= UInt8('f') ? b - UInt8('a') + 0x0a : 0xff

"""percent-decode one path segment or query component (`plus`: '+' → space)"""
function percentdecode(s::AbstractString; plus::Bool=false)
    bytes = codeunits(s)
    any(b -> b == UInt8('%') || (plus && b == UInt8('+')), bytes) || return String(s)
    out = IOBuffer()
    i, n = 1, length(bytes)
    while i <= n
        b = bytes[i]
        if b == UInt8('%') && i + 2 <= n
            hi, lo = _hexval(bytes[i + 1]), _hexval(bytes[i + 2])
            if hi != 0xff && lo != 0xff
                write(out, hi << 4 | lo)
                i += 3
                continue
            end
        end
        write(out, plus && b == UInt8('+') ? UInt8(' ') : b)
        i += 1
    end
    return String(take!(out))
end

"""decode a raw query string into ordered key => value pairs"""
function querypairs(query::AbstractString)
    pairs = Pair{String, String}[]
    isempty(query) && return pairs
    for part in split(query, '&'; keepempty=false)
        eq = findfirst(==('='), part)
        if eq === nothing
            push!(pairs, percentdecode(part; plus=true) => "")
        else
            key = SubString(part, firstindex(part), prevind(part, eq))
            value = SubString(part, nextind(part, eq))
            push!(pairs, percentdecode(key; plus=true) => percentdecode(value; plus=true))
        end
    end
    return pairs
end

# Raw handlers and auth schemes receive the request from the type-erased
# HandlerCall slot. `HTTP.Request` is parametric in its body type, so a call on
# the erased value would need run-time dispatch, which juliac --trim cannot
# verify. Narrow first to the request types HTTP.jl's server produces, plus
# in-process requests built with a `String` body. `httponly` (constant-folded
# from the callee's methods) drops the open fallback for callees that only
# accept `HTTP.Request`.
@inline function withrequest(f::F, @nospecialize(req), httponly::Bool) where {F}
    req isa HTTP.Request{HTTP.BytesBody{Vector{UInt8}}} && return f(req)
    req isa HTTP.Request{HTTP.EmptyBody} && return f(req)
    req isa HTTP.Request{HTTP.BytesBody{Base.CodeUnits{UInt8, String}}} && return f(req)
    httponly && error("unsupported HTTP request body type for an HTTP.Request-typed handler")
    return f(req) # other transports' request types
end

"""
    Servo.withrequest(f)

Call `f(request)` with the current raw transport request (see
[`Servo.request`](@ref)). Typed endpoints use it to read the raw request, e.g.
`Servo.withrequest(req::HTTP.Request -> String(req.body))`. On HTTP the request
is narrowed to a concrete type first, so the call stays statically dispatched
under juliac --trim when `f` accepts only `HTTP.Request`.
"""
withrequest(f::F) where {F} = withrequest(f, request(), httponly(f))

# true when the callee accepts `HTTP.Request` but not arbitrary values; inference
# folds `hasmethod` for a concrete callee type
httponly(f) = hasmethod(f, Tuple{HTTP.Request}) && !hasmethod(f, Tuple{Any})
httponly(auth::AuthScheme) = hasmethod(authenticate, Tuple{typeof(auth), HTTP.Request}) &&
    !hasmethod(authenticate, Tuple{typeof(auth), Any})

function bearertoken(@nospecialize(req::HTTP.Request))
    # Reached through checkauth's Any-typed request slot: `@nospecialize` gives
    # one statically-invokable instance, and dispatching the header lookup on
    # the headers vector (not the request) keeps it concrete even though the
    # request type here is the abstract `Request` UnionAll.
    header = strip(String(HTTP.header(req.headers, "Authorization", "")))
    isempty(header) && return nothing
    parts = split(header)
    length(parts) == 2 || return nothing
    lowercase(String(parts[1])) == "bearer" || return nothing
    return String(parts[2])
end

"""
Header that carries the client address set by a trusted proxy, such as
`"Fly-Client-IP"` or `"X-Forwarded-For"`. Empty (the default) trusts only the
transport peer. `Servo.run!` sets it from the `client_ip_header` config key.
"""
const CLIENT_IP_HEADER = Ref("")

function clientip(req::HTTP.Request)
    name = CLIENT_IP_HEADER[]
    if !isempty(name)
        # A proxy appends the address it saw to the end of X-Forwarded-For,
        # sometimes as its own header line; earlier entries and lines come from
        # the client and can be forged.
        values = HTTP.headers(req.headers, name)
        isempty(values) || return String(strip(last(split(last(values), ','))))
    end
    # the context slot is Any-typed; narrowing here keeps `handle`'s client-key
    # conversion statically dispatched under juliac --trim
    ip = get(HTTP.get_request_context(req), :peerip, nothing)
    return ip isa String ? ip : nothing
end

"""
    Servo.httphandler(router; onerror=nothing) -> f(::HTTP.Request)::HTTP.Response

The HTTP request handler for a router: match, `Servo.handle`, and translate
results/errors into HTTP responses. `HEAD` requests are routed like `GET`
(HTTP.jl sends no body; a streaming body is closed before it is returned).
Errors are serialized into a stable `(; error = (; message, code))` envelope
with the endpoint's format (plain text when no endpoint was matched).

`onerror(exception, endpoint, request)` runs first for every exception,
including Servo's own 404/405/401/400 `HTTPError`s, while the backtrace is still
available. It returns a `Servo.Response` to send, or `nothing` for the default
mapping: `HTTPError` → its status, `ArgumentError` → 400, anything else → a
logged, sanitized 500. `endpoint` is `nothing` when no route matched.

A raw handler may return an `HTTP.Response`. Buffered bodies (strings and byte
vectors) are sent as usual; any other body, such as an SSE stream, is streamed
through a [`Servo.StreamBody`](@ref), so the handler's return type stays a
closed set under juliac --trim. Return a concretely inferred response type:
an abstractly typed `HTTP.Response` (e.g. from a function declared
`::HTTP.Response`) costs a dynamic dispatch.
"""
function httphandler(router::Router; onerror::E=nothing) where {E}
    return function(req::HTTP.Request)
        ep = nothing
        try
            path, _ = splittarget(req.target)
            segments = String[percentdecode(s) for s in splitsegments(path)]
            method = req.method == "HEAD" ? :GET : Symbol(req.method)
            m = matchroute(router, method, segments)
            m === nothing && throw(HTTPError(404, "no route for $(req.method) $path"))
            m === :method_not_allowed &&
                throw(HTTPError(405, "$(req.method) not allowed for $path"))
            ep, pathparams = m
            resp = handle(ep, pathparams, req)
            resp isa NativeResponse || return httpresponse(resp)
            native = resp.response::HTTP.Response{StreamBody}
            # HTTP.jl's stream server reads a body to its end even for HEAD,
            # and an endless stream (SSE) has no end: close it up front.
            req.method == "HEAD" && HTTP.body_close!(native.body)
            return native
        catch e
            if onerror !== nothing
                r = onerror(e, ep, req)
                r === nothing || return httpresponse(r::Response)
            end
            # Narrow the catch value before reading its fields. A catch value
            # has type Any, so passing it through a generic error-mapping helper
            # leaves dynamic dispatch in every compiled HTTP.Request method.
            # These branches preserve the public policy and keep the transport
            # statically callable under JuliaC --trim.
            if e isa HTTPError
                return errorresponse(ep, e)
            elseif e isa ArgumentError
                return errorresponse(ep, HTTPError(400, argmsg(e)))
            end
            @error "unhandled exception in endpoint $(ep === nothing ? "<unmatched>" : ep.name)" exception=(e, catch_backtrace())
            return errorresponse(ep, HTTPError(500, "internal server error"))
        end
    end
end

# Branch on the body union so each HTTP.Response constructor call is concrete,
# and pass the body positionally: HTTP's `body=` keyword adds an `EmptyBody`
# result type. With StreamBody, httphandler returns three concrete response
# types; a fourth would widen to the abstract `HTTP.Response`, leaving the
# server's write path dynamically dispatched under juliac --trim.
function httpresponse(r::Response)
    body = r.body
    body isa String && return HTTP.Response(r.status, body; headers=r.headers)
    return HTTP.Response(r.status, body::Vector{UInt8}; headers=r.headers)
end

# An HTTP.Response returned by a raw handler: buffered bodies become a
# Servo.Response (without copying a byte vector); any other body is streamed
# through a StreamBody.
function toresponse(::Format, r::HTTP.Response)
    b = r.body
    body = b isa String ? b :
        b isa Vector{UInt8} ? b :
        b isa HTTP.EmptyBody ? UInt8[] :
        b isa HTTP.BytesBody ? (b.data isa Vector{UInt8} ? b.data : Vector{UInt8}(b.data)) :
        nothing
    body === nothing || return Response(r.status, body; headers=r.headers)
    resp = HTTP.Response(r.status, StreamBody(b); reason=r.reason, headers=r.headers,
        trailers=r.trailers, content_length=r.content_length,
        proto_major=r.proto_major, proto_minor=r.proto_minor, close=r.close)
    # set after construction: a Union-typed keyword makes the call dynamic
    resp.request = r.request
    return NativeResponse(resp)
end

"""
    Servo.StreamBody(body::HTTP.AbstractBody)

Any HTTP.jl response body behind one concrete type. Servo wraps streaming
bodies returned by raw handlers in it, so [`Servo.httphandler`](@ref) returns
a closed set of response types and the server's write path stays statically
dispatched under juliac --trim. Each body method calls the wrapped body through
a function pointer specialized on its type (the [`HandlerFn`](@ref) trick).
"""
struct StreamBody <: HTTP.AbstractBody
    read::Ptr{Cvoid}
    close::Ptr{Cvoid}
    closed::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    root::Any # keeps the wrapped body alive; never dispatched on
end

_bodyread(b::B, dst::Ptr{Cvoid}) where {B} = HTTP.body_read!(b, unsafe_pointer_to_objref(dst)::Vector{UInt8})::Int
_bodyclose(b::B) where {B} = (HTTP.body_close!(b); nothing)
_bodyclosed(b::B) where {B} = HTTP.body_closed(b)::Bool

function StreamBody(b::B) where {B <: HTTP.AbstractBody}
    objref = Base.cconvert(Ref{B}, b)
    return StreamBody(@cfunction(_bodyread, Int, (Ref{B}, Ptr{Cvoid})),
                      @cfunction(_bodyclose, Cvoid, (Ref{B},)),
                      @cfunction(_bodyclosed, Bool, (Ref{B},)),
                      Ptr{Cvoid}(Base.unsafe_convert(Ref{B}, objref)), objref)
end

HTTP.body_read!(s::StreamBody, dst::Vector{UInt8}) =
    GC.@preserve s dst ccall(s.read, Int, (Ptr{Cvoid}, Ptr{Cvoid}), s.objptr, pointer_from_objref(dst))
HTTP.body_close!(s::StreamBody) = GC.@preserve s ccall(s.close, Cvoid, (Ptr{Cvoid},), s.objptr)
HTTP.body_closed(s::StreamBody) = GC.@preserve s ccall(s.closed, Bool, (Ptr{Cvoid},), s.objptr)

function errorresponse(ep::Union{Endpoint, Nothing}, e::HTTPError)
    status, message = e.status, e.message
    headers = Pair{String, String}["Content-Type" =>
        ep === nothing ? "text/plain; charset=utf-8" : mime(ep.format)]
    if e.body !== nothing
        body = e.body
    elseif ep !== nothing
        body = try
            errorbody(ep.format, message, status)
        catch
            message
        end
    else
        body = message
    end
    for h in e.headers
        filter!(x -> lowercase(x.first) != lowercase(h.first), headers)
        push!(headers, h)
    end
    return httpresponse(Response(status, body; headers))
end

const CORS_ALLOW_HEADERS = "Origin, X-Requested-With, Content-Type, Accept, Authorization"
const CORS_ALLOW_METHODS = "GET, POST, PUT, DELETE, PATCH, QUERY, OPTIONS"

"""
    Servo.cors_middleware(handler, origins=nothing)

Answer CORS preflight (`OPTIONS`) requests with a 204 and add CORS headers to
responses. With `origins === nothing`, every origin may read responses, but
without credentials (`Access-Control-Allow-Origin: *`), so browsers don't send
cookies and other sites can't read a signed-in user's data. With a list, only
exact matches are allowed: an allowed `Origin` is echoed back with credentials
allowed, and every response carries `Vary: Origin`.

Preflight responses allow the headers the browser asked for.
"""
function cors_middleware(handler, origins::Union{Nothing, Vector{String}}=nothing)
    return function(req::HTTP.Request)
        preflight = req.method == "OPTIONS"
        # Answer preflight directly so endpoints never deal with OPTIONS. A
        # byte-vector body keeps this one of httphandler's three response types.
        resp = preflight ? HTTP.Response(204, UInt8[]) : handler(req)
        if origins === nothing
            HTTP.setheader(resp.headers, "Access-Control-Allow-Origin" => "*")
        else
            # The response depends on Origin even when it is denied, so shared
            # caches must not reuse it across origins.
            vary = HTTP.header(resp.headers, "Vary", "")
            HTTP.setheader(resp.headers, "Vary" => isempty(vary) ? "Origin" : vary * ", Origin")
            origin = HTTP.header(req.headers, "Origin", "")
            (isempty(origin) || !(origin in origins)) && return resp
            HTTP.setheader(resp.headers, "Access-Control-Allow-Origin" => origin)
            HTTP.setheader(resp.headers, "Access-Control-Allow-Credentials" => "true")
        end
        if preflight
            requested = HTTP.header(req.headers, "Access-Control-Request-Headers", "")
            HTTP.setheader(resp.headers, "Access-Control-Allow-Headers" =>
                isempty(requested) ? CORS_ALLOW_HEADERS : requested)
            HTTP.setheader(resp.headers, "Access-Control-Allow-Methods" => CORS_ALLOW_METHODS)
        end
        return resp
    end
end

function accesslog_middleware(handler)
    return function(req::HTTP.Request)
        start = time()
        resp = handler(req)
        # The path only: query strings can carry tokens or personal data.
        path, _ = splittarget(req.target)
        @info "$(req.method) $path" status=resp.status duration_ms=round(Int, (time() - start) * 1000)
        return resp
    end
end

"""
    Servo.serve!(router=Servo.ROUTER; host="0.0.0.0", port=8080, middleware=identity,
                 onerror=nothing, cors=false, accesslog=false, kw...)

Start (non-blocking) an HTTP server for a router and return the server handle
(`wait` it to block, `close` it to stop). Prefer [`Servo.run!`](@ref), which also
loads config and applies profile conventions; `serve!` is the bare transport
entrypoint. Remaining `kw` pass through to `HTTP.listen!`.

`middleware` is called once with Servo's HTTP request handler and must return a
request handler. It can mount a protocol-native handler before Servo routing,
including handlers that return streaming HTTP response bodies. Servo's CORS and
access-log middleware wrap the result, so they also cover mounted paths.

`onerror` maps exceptions to responses; see [`Servo.httphandler`](@ref).

`cors` is `false` (no CORS headers), `true` (every origin, without credentials),
or a `Vector{String}` of allowed origins (with credentials); see
[`Servo.cors_middleware`](@ref).

Statically compiled (juliac --trim) deployments should skip `serve!` and serve
a composed handler through HTTP.jl's request-handler path directly — its
runtime `cors`/`accesslog` flags make every middleware composition and the
stream-server path statically reachable, and the stream path's body plumbing
is not trim-verifiable:

    HTTP.serve!(Servo.cors_middleware(Servo.httphandler(router)), host, port)

That path never sees the transport peer, so set `Servo.CLIENT_IP_HEADER[]` to
the header your proxy sets (e.g. `"Fly-Client-IP"`); otherwise every client
shares one public rate-limit bucket.
"""
function serve!(router::Router=ROUTER; host="0.0.0.0", port::Integer=8080,
                middleware=identity, onerror=nothing, cors::Union{Bool, Vector{String}}=false,
                accesslog::Bool=false, kw...)
    handler = middleware(httphandler(router; onerror))
    applicable(handler, HTTP.Request("GET", "/")) || throw(ArgumentError(
        "middleware must return a handler callable with an HTTP.Request",
    ))
    cors === false || (handler = cors_middleware(handler, cors === true ? nothing : cors))
    accesslog && (handler = accesslog_middleware(handler))

    # Use HTTP.jl's stream server because it exposes the transport peer before
    # the request handler runs. The public `peeraddr` API works for HTTP/1 and
    # HTTP/2, including TLS connections.
    return HTTP.listen!(host, port; kw...) do stream
        peer = HTTP.peeraddr(stream)
        requesthandler = HTTP.streamhandler() do req
            peer === nothing ||
                (HTTP.get_request_context(req)[:peerip] = String(_peerip(peer)))
            return handler(req)
        end
        return requesthandler(stream)
    end
end

function _peerip(peer)
    endpoint = string(peer)
    if startswith(endpoint, '[')
        closing = findfirst(==(']'), endpoint)
        closing === nothing || return endpoint[2:prevind(endpoint, closing)]
    end
    parts = rsplit(endpoint, ':'; limit=2)
    return length(parts) == 2 ? first(parts) : endpoint
end

"""the local port a server (returned by `serve!`/`run!`) is bound to"""
port(server::HTTP.Server) = HTTP.port(server)
