# JuliaC --trim=safe workload for Servo's core machinery: endpoint declaration
# (macros + validation), routing, statically-bound argument extraction/coercion,
# auth, public rate limiting, formats (TextFormat + the JSON extension), and
# Figgy-backed config loading — exercised over a minimal non-HTTP transport. The
# HTTP transport itself lives in the ServoHTTPExt extension and is deliberately
# not part of this workload: released HTTP 1.x (MbedTLS/OpenSSL init) is not
# trim-verifiable.
using Servo, JSON

struct TrimRequest
    query::Vector{Pair{String, String}}
    body::Union{Nothing, String}
    ip::Union{Nothing, String}
end
TrimRequest(; query = Pair{String, String}[], body = nothing, ip = nothing) =
    TrimRequest(query, body, ip)
Servo.rawquery(r::TrimRequest) = r.query
Servo.rawbody(r::TrimRequest) = r.body
Servo.clientip(r::TrimRequest) = r.ip

struct TrimAuth <: Servo.AuthScheme
    key::String
end
Servo.authenticate(a::TrimAuth, req::TrimRequest) =
    any(kv -> kv.first == "key" && kv.second == a.key, req.query) ? "trim-user" : nothing

struct TrimWidget
    id::Int
    tags::Vector{String}
end

# endpoints are declared at top level (the normal app-module pattern), so the
# handler functions are const globals and the endpoint values are fully concrete
const ROUTER = Servo.Router()

const EP_ITEM = Servo.@GET ROUTER "/items/{id}" public format=Servo.TextFormat() function getitem(
        id::Int; verbose::Bool=false, tags::Vector{String}=String[],
        limit::Union{Nothing, Int}=nothing, owner::String)
    "id=$id verbose=$verbose tags=$(join(tags, '|')) limit=$limit owner=$owner"
end

const EP_DEL = Servo.@DELETE ROUTER "/items/{id}" public format=Servo.TextFormat() function rmitem(id::Int)
    nothing
end

const EP_ECHO = Servo.@POST ROUTER "/echo" public format=Servo.TextFormat() function echo(msg::String)
    Servo.Response(201, uppercase(msg))
end

# JSON response serialization; note the trim workload deliberately has no
# JSONFormat *body* argument — typed `JSON.parse` materialization is a known
# open trim gap in JSON.jl itself (see JSON's own trim entrypoints test), while
# `JSON.json` writing is trim-clean. Servo's body-binding code path is still
# verified via the TextFormat endpoints above.
const EP_WIDGET = Servo.@GET ROUTER "/widgets/{id}" public function getwidget(id::Int; dry::Bool=false)
    (; ok = !dry, id, n = 2)
end

const EP_SECRET = Servo.@GET ROUTER "/secret" TrimAuth("open-sesame") format=Servo.TextFormat() function secret()
    Servo.principal() isa String ? "granted" : "no-principal"
end

const EP_PUB = Servo.@GET ROUTER "/pub" public format=Servo.TextFormat() function pub()
    "ok"
end

const NOPARAMS = Dict{Symbol, String}()

function _trim_assert(condition::Bool, msg::AbstractString)::Nothing
    condition || error(msg)
    return nothing
end

function _expect_httperror(f, status::Int, msg::AbstractString)::Nothing
    try
        f()
        error("$msg: expected HTTPError($status)")
    catch e
        e isa Servo.HTTPError || rethrow()
        e.status == status || error("$msg: expected status $status, got $(e.status)")
    end
    return nothing
end

function _expect_argumenterror(f, msg::AbstractString)::Nothing
    try
        f()
        error("$msg: expected ArgumentError")
    catch e
        e isa ArgumentError || rethrow()
    end
    return nothing
end

function _trim_routing()::Nothing
    m = Servo.matchroute(ROUTER, "GET", "/items/42")
    _trim_assert(m isa Tuple, "matchroute should match")
    if m isa Tuple
        pathparams = m[2]::Dict{Symbol, String}
        _trim_assert(pathparams[:id] == "42", "path param captured")
    end
    _trim_assert(Servo.matchroute(ROUTER, "PUT", "/items/42") === :method_not_allowed, "405")
    _trim_assert(Servo.matchroute(ROUTER, "GET", "/nope") === nothing, "404")
    _trim_assert(length(ROUTER.endpoints) == 6, "route table size")
    return nothing
end

function _trim_binding()::Nothing
    resp = Servo.handle(EP_ITEM, Dict(:id => "7"),
        TrimRequest(; query = ["owner" => "jake", "verbose" => "true", "tags" => "a,b", "limit" => "3"]))
    _trim_assert(resp.status == 200, "getitem status")
    _trim_assert(resp.body == "id=7 verbose=true tags=a|b limit=3 owner=jake", "getitem body")
    resp = Servo.handle(EP_ITEM, Dict(:id => "7"), TrimRequest(; query = ["owner" => "jake"]))
    _trim_assert(resp.body == "id=7 verbose=false tags= limit=nothing owner=jake", "getitem defaults")

    _expect_httperror(400, "missing required query param") do
        Servo.handle(EP_ITEM, Dict(:id => "7"), TrimRequest())
    end
    _expect_httperror(400, "bad path param") do
        Servo.handle(EP_ITEM, Dict(:id => "abc"), TrimRequest(; query = ["owner" => "j"]))
    end
    _expect_httperror(400, "bad query param") do
        Servo.handle(EP_ITEM, Dict(:id => "7"), TrimRequest(; query = ["owner" => "j", "limit" => "many"]))
    end

    # nothing -> 204; Servo.Response passthrough; empty body -> 400
    _trim_assert(Servo.handle(EP_DEL, Dict(:id => "1"), TrimRequest()).status == 204, "204")
    resp = Servo.handle(EP_ECHO, NOPARAMS, TrimRequest(; body = "hey"))
    _trim_assert(resp.status == 201 && resp.body == "HEY", "response passthrough")
    _expect_httperror(400, "missing body") do
        Servo.handle(EP_ECHO, NOPARAMS, TrimRequest())
    end
    return nothing
end

function _trim_json()::Nothing
    _trim_assert(JSON.json(TrimWidget(1, ["x"])) == "{\"id\":1,\"tags\":[\"x\"]}", "json struct write")
    resp = Servo.handle(EP_WIDGET, Dict(:id => "9"), TrimRequest())
    _trim_assert(resp.status == 200, "json status")
    _trim_assert(resp.headers == ["Content-Type" => "application/json; charset=utf-8"], "json content type")
    _trim_assert(resp.body == "{\"ok\":true,\"id\":9,\"n\":2}", "json response")
    resp = Servo.handle(EP_WIDGET, Dict(:id => "9"), TrimRequest(; query = ["dry" => "true"]))
    _trim_assert(resp.body == "{\"ok\":false,\"id\":9,\"n\":2}", "json response with query")
    return nothing
end

function _trim_auth_and_ratelimit()::Nothing
    resp = Servo.handle(EP_SECRET, NOPARAMS, TrimRequest(; query = ["key" => "open-sesame"]))
    _trim_assert(resp.body == "granted", "auth principal")
    _trim_assert(Servo.principal() === nothing, "principal cleared outside request")
    _expect_httperror(401, "bad credentials") do
        Servo.handle(EP_SECRET, NOPARAMS, TrimRequest(; query = ["key" => "wrong"]))
    end

    rl = Servo.RateLimiter(; rps = 10.0, burst = 2.0)
    _trim_assert(Servo.allow!(rl, ("a", "1.2.3.4")), "bucket 1")
    _trim_assert(Servo.allow!(rl, ("a", "1.2.3.4")), "bucket 2")
    _trim_assert(!Servo.allow!(rl, ("a", "1.2.3.4")), "bucket exhausted")
    _trim_assert(Servo.allow!(rl, ("a", "5.6.7.8")), "separate key")

    Servo.PUBLIC_RATE_LIMITER[] = Servo.RateLimiter(; rps = 0.1, burst = 1.0)
    try
        _trim_assert(Servo.handle(EP_PUB, NOPARAMS, TrimRequest(; ip = "1.2.3.4")).status == 200, "public ok")
        _expect_httperror(429, "public rate limited") do
            Servo.handle(EP_PUB, NOPARAMS, TrimRequest(; ip = "1.2.3.4"))
        end
    finally
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end
    return nothing
end

function _trim_validation()::Nothing
    _expect_argumenterror("missing auth") do
        Servo.Endpoint(; method = :GET, path = "/x", target = () -> 1, format = Servo.TextFormat())
    end
    _expect_argumenterror("body arg on GET") do
        Servo.Endpoint(; method = :GET, path = "/x", target = () -> 1,
            params = [Servo.Param(:b, String, :body)],
            auth = Servo.Public(), format = Servo.TextFormat())
    end
    _expect_argumenterror("path/arg mismatch") do
        Servo.Endpoint(; method = :GET, path = "/a/{id}", target = () -> 1,
            auth = Servo.Public(), format = Servo.TextFormat())
    end
    return nothing
end

function _writefile(path::String, content::String)::Nothing
    # avoid the vararg `open(f, path, mode...)` method: its splat is dynamic under trim
    io = open(path, "w")
    write(io, content)
    close(io)
    return nothing
end

function _trim_config()::Nothing
    # ambient env would (correctly) override the config files; scrub for determinism
    delete!(ENV, "PORT")
    delete!(ENV, "PROFILE")
    delete!(ENV, "VERSION")
    configdir = mktempdir()
    _writefile(joinpath(configdir, "config.toml"), "greeting = \"base\"\nport = 8080\n")
    _writefile(joinpath(configdir, "config-trimtest.toml"), "greeting = \"hello trim\"\n\n[database]\nhost = \"localhost\"\n")
    _writefile(joinpath(configdir, ".config-trimtest.toml"), "apikey = \"shh\"\n")
    prof = Servo.loadconfig!(; profile = "trimtest", configdir, log = false)
    _trim_assert(prof == "trimtest", "profile resolved")
    _trim_assert(Servo.profile() == "trimtest", "profile()")
    _trim_assert((Servo.config("greeting")::String) == "hello trim", "profile overrides base")
    _trim_assert((Servo.config("database.host")::String) == "localhost", "dotted key")
    _trim_assert((Servo.config("apikey")::String) == "shh", "secrets file")
    _trim_assert((Servo.config("port")::Int) == 8080, "base config")
    _trim_assert((Servo.config("missing", "fallback")::String) == "fallback", "default")
    rm(configdir; recursive = true, force = true)
    return nothing
end

function run_servo_trim_sample()::Nothing
    _trim_routing()
    _trim_binding()
    _trim_json()
    _trim_auth_and_ratelimit()
    _trim_validation()
    _trim_config()
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_servo_trim_sample()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
