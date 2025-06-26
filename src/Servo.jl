module Servo

using Logging, Dates, HTTP, JSON, Figgy, DBInterface, Postgres, Tables, ConcurrentUtilities, ScopedValues

precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

mutable struct Done
    @atomic done::Bool
    Done() = new(false)
end

isdone(d::Done) = @atomic(:acquire, d.done)
done!(d::Done) = @atomic(:release, d.done = true)

const CONFIGS = Figgy.Store()
getConfig(key::String, default=nothing) = get(CONFIGS, key, default)

include("json_logging.jl")
include("json_middleware.jl")
# include("auth_middleware.jl")
include("routing.jl")
include("uids/UIDs.jl"); using .UIDs
include("obs.jl"); using .Obs
include("postgres.jl")
include("crypt.jl"); using .Crypt
include("minihmac.jl"); using .MiniHMAC

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
const ROUTER = Ref{HTTP.Router}(HTTP.Router())

function __init__()
    if !precompiling()
        HTTP.register!(PUBLIC_ROUTER, "/**", ROUTER[])
        HTTP.register!(PUBLIC_ROUTER, "/v1/status", req -> HTTP.Response(200))
        HTTP.register!(PUBLIC_ROUTER, "/v1/version", req -> HTTP.Response(200, VERSION[]))
    end
end

function init(; service="Servo", profile="", configs=Dict(), configdir=nothing, auth_middleware=nothing, log::Bool=!isinteractive())
    @info "$service init" CPU_NAME=Sys.CPU_NAME nInteractiveThreads=Threads.threadpoolsize(:interactive) nDefaultThreads=Threads.threadpoolsize(:default)
    # load config
    Figgy.load!(CONFIGS, configs, Figgy.ProgramArguments(), Figgy.EnvironmentVariables(), configdir !== nothing ? Figgy.TomlObject(joinpath(configdir, "config.toml")) : Dict(); log)
    # load profile-specific config
    if !isempty(profile)
        Figgy.load!(CONFIGS, Dict("profile" => profile); log)
    end
    profile = getConfig("profile", "local")
    version = getConfig("version", "unknown")
    if configdir !== nothing
        file = joinpath(configdir, "config-$profile.toml")
        isfile(file) && Figgy.load!(CONFIGS, Figgy.TomlObject(file); log)
        file = joinpath(configdir, ".config-$profile.toml")
        isfile(file) && Figgy.load!(CONFIGS, Figgy.TomlObject(file); log)
    end
    @info "Servo config loaded" profile=profile version=version
    if auth_middleware !== nothing
        ROUTER[] = HTTP.Router(HTTP.Handlers.default404, HTTP.Handlers.default405, auth_middleware)
    end
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

function cors_middleware(handler)
    return function(req::HTTP.Request)
        res = handler(req)
        HTTP.setheader(res.headers, "Access-Control-Allow-Origin" => "*")
        HTTP.setheader(res.headers, "Access-Control-Allow-Headers" => "Origin, X-Requested-With, Content-Type, Accept, Authorization")
        HTTP.setheader(res.headers, "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS")
        HTTP.setheader(res.headers, "Access-Control-Allow-Credentials" => "true")
        return res
    end
end

_int(x) = x isa Int ? x : parse(Int, x)

function run!(service=getConfig("service", "Servo"), profile=getConfig("profile", "local"), port=getConfig("port", 8080); kw...)
    profile = Servo.init(; service=service, profile=profile, kw...)
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
