precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

"""
    Servo.@init begin ... end

Define your app module's `__init__` with the body guarded against running during
precompilation. Endpoint registration mutates runtime state, so it must happen at
load time — put your `@GET`/`@POST`/… declarations (or `register!` calls) inside
`Servo.@init` at the top level of your app module.
"""
macro init(expr)
    esc(quote
        function __init__()
            if !Servo.precompiling()
                $expr
            end
        end
    end)
end

_int(x::Integer) = Int(x)
_int(x) = parse(Int, string(x))
_float(x::Real) = Float64(x)
_float(x) = parse(Float64, string(x))

"""
    Servo.run!(name="Servo", profile=""; kw...) -> server

Start an app: load configuration for `profile` (see [`loadconfig!`](@ref)),
install the public-endpoint rate limiter, register the builtin `/status` and
`/version` endpoints, and serve the router over HTTP. Returns the server handle
(non-blocking); use [`Servo.run`](@ref) to block until interrupted.

The `local` profile (the default) enables permissive CORS for browser-based
development; other profiles do not.

Keywords: `router=Servo.ROUTER`, `host="0.0.0.0"`, `port=nothing` (falls back to
the `port` config key, then 8080), `configdir=nothing`, `configs=Dict()`,
`accesslog=true`, `log=!isinteractive()`.
"""
function run!(name::AbstractString="Servo", profile::AbstractString="";
              router::Router=ROUTER, host="0.0.0.0", port::Union{Integer, Nothing}=nothing,
              configdir::Union{AbstractString, Nothing}=nothing, configs=Dict{String, Any}(),
              accesslog::Bool=true, log::Bool=!isinteractive())
    @info "$name init" julia=Base.VERSION threads=Threads.nthreads()
    prof = loadconfig!(; profile, configdir, configs, log)
    p = _int(something(port, config("port", 8080)))
    PUBLIC_RATE_LIMITER[] = RateLimiter(;
        rps=_float(config("public_ratelimit_rps", 5.0)),
        burst=_float(config("public_ratelimit_burst", 20.0)))
    registerbuiltins!(router)
    cors = prof == "local"
    server = serve!(router; host, port=p, cors, accesslog)
    @info "$name listening" profile=prof host port=Servo.port(server) cors endpoints=length(router.endpoints)
    return server
end

"""
    Servo.run(name="Servo", profile=""; kw...)

[`run!`](@ref), then block until the process is interrupted (SIGINT/`close`),
shutting the server down cleanly. This is the entrypoint for deployed apps:
`julia -e 'using MyApp; MyApp.run()'`.
"""
function run(args...; kw...)
    server = run!(args...; kw...)
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        @info "shutting down"
        close(server)
    end
    return
end

function registerbuiltins!(router::Router)
    if !(matchroute(router, :GET, ["status"]) isa Tuple)
        register!(router, Endpoint(; name="status", method=:GET, path="/status",
            target=() -> "ok", auth=Public(), format=TextFormat()))
    end
    if !(matchroute(router, :GET, ["version"]) isa Tuple)
        register!(router, Endpoint(; name="version", method=:GET, path="/version",
            target=() -> string(config("version", "unknown")), auth=Public(), format=TextFormat()))
    end
    return router
end
