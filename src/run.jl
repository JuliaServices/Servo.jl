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

"""
    Servo.run!(name="Servo", profile=""; kw...) -> server

Start an app: load configuration for `profile` (see [`loadconfig!`](@ref)),
install the public-endpoint rate limiter, register the builtin `/status` and
`/version` endpoints, and serve the router over HTTP. Returns the server handle
(non-blocking); use [`Servo.run`](@ref) to block until interrupted.

Config keys read here:

- `cors_origins`: browser origins allowed by CORS (with credentials), as a list
  or a comma-separated string. When unset, the `local` profile (the default)
  allows every origin without credentials and other profiles send no CORS
  headers.
- `client_ip_header`: the header a trusted proxy sets to the client address
  (e.g. `Fly-Client-IP`), used to key public rate limiting. When unset, Servo
  uses the connection's peer address. Behind a proxy, set it, or every client
  shares one bucket. Only name a header your proxy overwrites, since clients
  can send any header themselves.
- `public_ratelimit_rps` / `public_ratelimit_burst`: see [`Servo.RateLimiter`](@ref).

Keywords: `router=Servo.ROUTER`, `host="0.0.0.0"`, `port=nothing` (falls back to
the `port` config key, then 8080), `configdir=nothing`, `configs=Dict()`,
`setup=Returns(nothing)`, `middleware=identity` and `onerror=nothing` (forwarded
to [`serve!`](@ref)), `builtins=true` (register `GET /status` and `/version`),
`accesslog=true`, `log=!isinteractive()`.

`setup` runs once after configuration is available and before Servo opens the
listener. Use it for required, idempotent startup work such as creating database
tables. If it throws, `run!` stops without starting the server.
"""
function run!(name::AbstractString="Servo", profile::AbstractString="";
              router::Router=ROUTER, host="0.0.0.0", port::Union{Integer, Nothing}=nothing,
              configdir::Union{AbstractString, Nothing}=nothing, configs=Dict{String, Any}(),
              setup::S=Returns(nothing), middleware::M=identity, onerror::E=nothing,
              builtins::Bool=true, accesslog::Bool=true, log::Bool=!isinteractive()) where {S, M, E}
    @info "$name init" julia=Base.VERSION threads=Threads.nthreads()
    prof = loadconfig!(; profile, configdir, configs, log)
    # Configuration must be ready before application provisioning runs. The
    # listener starts later, so a provisioning error cannot expose a partly
    # initialized service.
    setup()
    p = port === nothing ? config("port", 8080) : Int(port)
    PUBLIC_RATE_LIMITER[] = RateLimiter(;
        rps=config("public_ratelimit_rps", 5.0),
        burst=config("public_ratelimit_burst", 20.0))
    builtins && registerbuiltins!(router)
    CLIENT_IP_HEADER[] = config("client_ip_header", "")
    origins = config("cors_origins", nothing)
    cors = origins === nothing ? prof == "local" : _origins(origins)
    server = serve!(router; host, port=p, middleware, onerror, cors, accesslog)
    @info "$name listening" profile=prof host port=Servo.port(server) cors endpoints=length(router.endpoints)
    return server
end

# `cors_origins` is a TOML list of strings or a comma-separated string (from an
# environment variable or program argument). One method keeps the call on the
# untyped config value statically resolvable.
function _origins(@nospecialize(x))
    x isa String && return String[strip(o) for o in split(x, ',') if !isempty(strip(o))]
    x isa Vector{String} && return x
    x isa Vector{Any} && return String[o::String for o in x]
    throw(ArgumentError("config key \"cors_origins\" must be a list of strings or a comma-separated string"))
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
    # Registered through the same macro machinery as application endpoints so
    # the builtins get statically-typed binders: the closure-target Endpoint
    # path binds reflectively, which a juliac --trim=safe build cannot verify,
    # and trim apps previously had to hand-register static equivalents.
    if !(matchroute(router, :GET, ["status"]) isa Tuple)
        @GET router "/status" public format=TextFormat() function status()
            return "ok"
        end
    end
    if !(matchroute(router, :GET, ["version"]) isa Tuple)
        @GET router "/version" public format=TextFormat() function version()
            return string(config("version", "unknown"))
        end
    end
    return router
end
