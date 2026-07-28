# HTTP transport: implements the transport interface for HTTP.Request and owns
# the server lifecycle + HTTP-level middleware (error envelope, CORS, access log).

rawbody(req::HTTP.Request) = req.body
rawquery(req::HTTP.Request) = HTTP.URIs.queryparampairs(HTTP.URI(req.target))

function clientip(req::HTTP.Request)
    # trust X-Forwarded-For when present (set by the load balancer in real deploys)
    xff = HTTP.header(req, "X-Forwarded-For", "")
    isempty(xff) || return String(strip(first(split(xff, ','))))
    return get(req.context, :peerip, nothing)
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
            target = HTTP.URI(req.target)
            segments = [HTTP.URIs.unescapeuri(s) for s in splitsegments(target.path)]
            m = matchroute(router, Symbol(req.method), segments)
            m === nothing && throw(HTTPError(404, "no route for $(req.method) $(target.path)"))
            m === :method_not_allowed &&
                throw(HTTPError(405, "$(req.method) not allowed for $(target.path)"))
            ep, pathparams = m
            resp = handle(ep, pathparams, req)
            return HTTP.Response(resp.status, resp.headers, resp.body)
        catch e
            e isa HTTPError && return errorresponse(ep, e.status, e.message)
            @error "unhandled exception in endpoint $(ep === nothing ? "<unmatched>" : ep.name)" exception=(e, catch_backtrace())
            return errorresponse(ep, 500, "internal server error")
        end
    end
end

function errorresponse(ep::Union{Endpoint, Nothing}, status::Int, message::String)
    if ep !== nothing
        body = try
            serialize(ep.format, (; error = (; message, code = status)))
        catch
            message
        end
        return HTTP.Response(status, ["Content-Type" => mime(ep.format)], body)
    end
    return HTTP.Response(status, ["Content-Type" => "text/plain; charset=utf-8"], message)
end

const CORS_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "Origin, X-Requested-With, Content-Type, Accept, Authorization",
    "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, PATCH, OPTIONS",
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
entrypoint. Remaining `kw` pass through to `HTTP.serve!`.
"""
function serve!(router::Router=ROUTER; host="0.0.0.0", port::Integer=8080,
                cors::Bool=false, accesslog::Bool=false, kw...)
    handler = httphandler(router)
    cors && (handler = cors_middleware(handler))
    accesslog && (handler = accesslog_middleware(handler))
    streamhandler = HTTP.streamhandler(handler)
    return HTTP.serve!(host, port; stream=true, kw...) do stream
        peer = try Sockets.getpeername(stream) catch; nothing end
        peer === nothing || (stream.message.context[:peerip] = peer[1])
        streamhandler(stream)
    end
end

"""the local port a server (returned by `serve!`/`run!`) is bound to"""
port(server::HTTP.Server) = Int(Sockets.getsockname(server.listener.server)[2])
