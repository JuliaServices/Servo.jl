module Servo

using Logging, Dates, HTTP, JSON, Figgy, DBInterface, Postgres, Tables, ConcurrentUtilities

precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

mutable struct Done
    @atomic done::Bool
    Done() = new(false)
end

isdone(d::Done) = @atomic(:acquire, d.done)
done!(d::Done) = @atomic(:release, d.done = true)

include("json_logging.jl")
include("json_middleware.jl")
# include("auth_middleware.jl")
include("routing.jl")
include("uids/UIDs.jl"); using .UIDs
include("obs.jl"); using .Obs

const VERSION = Ref{String}("unknown")

function version_middleware(handler)
    return function(req::HTTP.Request)
        resp = handler(req)
        HTTP.setheader(resp.headers, "X-version" => VERSION[])
        return resp
    end
end

# public router routes to ROUTER by default
const PUBLIC_ROUTER = HTTP.Router(HTTP.Handlers.default404, HTTP.Handlers.default405, version_middleware)
const ROUTER = HTTP.Router()

function __init__()
    if !precompiling()
        HTTP.register!(PUBLIC_ROUTER, "/**", req -> ROUTER(req))
        HTTP.register!(PUBLIC_ROUTER, "/v1/status", req -> HTTP.Response(200))
        HTTP.register!(PUBLIC_ROUTER, "/v1/version", req -> HTTP.Response(200, VERSION[]))
        init(; log=false)
    end
end

const CONFIGS = Figgy.Store()

function init(; app="Servo", profile="", configs=Dict(), configdir=nothing, log::Bool=!isinteractive())
    @info "$app init" CPU_NAME=Sys.CPU_NAME nInteractiveThreads=Threads.threadpoolsize(:interactive) nDefaultThreads=Threads.threadpoolsize(:default)
    # load config
    Figgy.load!(CONFIGS, configs, Figgy.ProgramArguments(), Figgy.EnvironmentVariables(), configdir !== nothing ? Figgy.TomlObject(joinpath(configdir, "config.toml")) : Dict(); log)
    # load profile-specific config
    if !isempty(profile)
        Figgy.load!(CONFIGS, Dict("profile" => profile); log)
    end
    profile = get(CONFIGS, "profile", "local")
    version = get(CONFIGS, "version", "unknown")
    if configdir !== nothing
        file = joinpath(configdir, "config-$profile.toml")
        isfile(file) && Figgy.load!(CONFIGS, Figgy.TomlObject(file); log)
        file = joinpath(configdir, ".config-$profile.toml")
        isfile(file) && Figgy.load!(CONFIGS, Figgy.TomlObject(file); log)
    end
    @info "Servo config loaded" profile=profile version=version
    # initialize auth verifier
    # initialize_auth_verifier!()
    return profile
end

macro init(expr)
    esc(quote
        function __init__()
            if !Servo.precompiling()
                $expr
            end
        end
    end)
end

function run!(service, profile, port; kw...)
    profile = Servo.init(profile; kw...)
    # start server
    @info "Starting server" service=service profile=profile port=port
    if profile == "local"
        return HTTP.serve!(Servo.cors_middleware(Servo.PUBLIC_ROUTER), "0.0.0.0", _int(port))
    else
        return HTTP.serve!(Servo.PUBLIC_ROUTER, "0.0.0.0", _int(port))
    end
end

function run(args...; kw...)
    server = run!(args...; kw...)
    try
        wait(server)
    finally
        @info "Shutting down server"
        close(server)
    end
end

end
