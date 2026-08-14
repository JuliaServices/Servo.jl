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

function clientip(req::HTTP.Request)
    # trust X-Forwarded-For when present (set by the load balancer in real deploys)
    xff = HTTP.header(req, "X-Forwarded-For", "")
    isempty(xff) || return String(strip(first(split(xff, ','))))
    # the context slot is Any-typed; narrowing here keeps `handle`'s client-key
    # conversion statically dispatched under juliac --trim
    ip = get(HTTP.get_request_context(req), :peerip, nothing)
    return ip isa String ? ip : nothing
end

"""
    Servo.httphandler(router) -> f(::HTTP.Request)::HTTP.Response

The HTTP request handler for a router: match, `Servo.handle`, and translate
results/errors into HTTP responses. Errors are serialized into a stable
`(; error = (; message, code))` envelope with the endpoint's format (plain text
when no endpoint was matched).
"""
function httphandler(router::Router)
    return function(req::HTTP.Request)
        ep = nothing
        try
            path, _ = splittarget(req.target)
            segments = String[percentdecode(s) for s in splitsegments(path)]
            m = matchroute(router, Symbol(req.method), segments)
            m === nothing && throw(HTTPError(404, "no route for $(req.method) $path"))
            m === :method_not_allowed &&
                throw(HTTPError(405, "$(req.method) not allowed for $path"))
            ep, pathparams = m
            resp = handle(ep, pathparams, req)
            # branch on the body union so each HTTP.Response constructor call
            # is concrete (a union-typed `body` keyword widens the response
            # type past what the trim verifier can resolve on the write path)
            body = resp.body
            body isa String &&
                return HTTP.Response(resp.status; headers=resp.headers, body=body)
            return HTTP.Response(resp.status; headers=resp.headers, body=body::Vector{UInt8})
        catch e
            e isa HTTPError && return errorresponse(ep, e.status, e.message)
            # Documented v1 behavior the endpoint contract relies on: an
            # uncaught ArgumentError is a client error (domain validation),
            # not an internal fault.
            e isa ArgumentError && return errorresponse(ep, 400, e.msg)
            @error "unhandled exception in endpoint $(ep === nothing ? "<unmatched>" : ep.name)" exception=(e, catch_backtrace())
            return errorresponse(ep, 500, "internal server error")
        end
    end
end

function errorresponse(ep::Union{Endpoint, Nothing}, status::Int, message::String)
    if ep !== nothing
        body = try
            errorbody(ep.format, message, status)
        catch
            message
        end
        return HTTP.Response(
            status;
            headers=["Content-Type" => mime(ep.format)],
            body,
        )
    end
    return HTTP.Response(
        status;
        headers=["Content-Type" => "text/plain; charset=utf-8"],
        body=message,
    )
end

const CORS_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "Origin, X-Requested-With, Content-Type, Accept, Authorization",
    "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, PATCH, QUERY, OPTIONS",
    "Access-Control-Allow-Credentials" => "true",
]

function cors_middleware(handler)
    return function(req::HTTP.Request)
        # answer preflight directly so endpoints never deal with OPTIONS
        resp = req.method == "OPTIONS" ? HTTP.Response(204) : handler(req)
        for (k, v) in CORS_HEADERS
            HTTP.setheader(resp.headers, k => v)
        end
        return resp
    end
end

function accesslog_middleware(handler)
    return function(req::HTTP.Request)
        start = time()
        resp = handler(req)
        @info "$(req.method) $(req.target)" status=resp.status duration_ms=round(Int, (time() - start) * 1000)
        return resp
    end
end

"""
    Servo.serve!(router=Servo.ROUTER; host="0.0.0.0", port=8080, cors=false, accesslog=false, kw...)

Start (non-blocking) an HTTP server for a router and return the server handle
(`wait` it to block, `close` it to stop). Prefer [`Servo.run!`](@ref), which also
loads config and applies profile conventions; `serve!` is the bare transport
entrypoint. Remaining `kw` pass through to `HTTP.listen!`.

Statically compiled (juliac --trim) deployments should skip `serve!` and serve
a composed handler through HTTP.jl's request-handler path directly — its
runtime `cors`/`accesslog` flags make every middleware composition and the
stream-server path statically reachable, and the stream path's body plumbing
is not trim-verifiable:

    HTTP.serve!(Servo.cors_middleware(Servo.httphandler(router)), host, port)

That path never sees the transport peer, so [`Servo.clientip`](@ref) falls
back to `X-Forwarded-For` alone.
"""
function serve!(router::Router=ROUTER; host="0.0.0.0", port::Integer=8080,
                cors::Bool=false, accesslog::Bool=false, kw...)
    handler = httphandler(router)
    cors && (handler = cors_middleware(handler))
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
