# JuliaC --trim=safe workload for Servo's core machinery: endpoint declaration
# (macros + validation), routing, the type-erased handler path (HandlerFn),
# statically-bound argument extraction/coercion, auth, public rate limiting,
# formats (TextFormat + the JSON extension), and Figgy-backed config loading —
# exercised over a minimal non-HTTP transport.
#
# The app is built at *runtime* (from main), the required pattern for endpoints:
# their type-erased handlers capture function pointers that would go stale if
# baked into a compile-time image. Requests are dispatched through endpoints
# returned by `matchroute` — the erased handler path needs no concretely-typed
# endpoint references.
#
# Known upstream trim limitations (allowlisted by the harness, see
# trim_compile_tests.jl): ScopedValues.jl forwards to Base.ScopedValues on
# current Julia, whose scope storage is not yet trim-verifiable. Typed
# `JSON.parse` materialization is likewise a known JSON.jl gap, so the JSON
# format is exercised on the write side (TextFormat covers body binding).
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

function _buildapp()
    r = Servo.Router()
    Servo.@GET r "/items/{id}" public format=Servo.TextFormat() function getitem(
            id::Int; verbose::Bool=false, tags::Vector{String}=String[],
            limit::Union{Nothing, Int}=nothing, owner::String)
        "id=$id verbose=$verbose tags=$(join(tags, '|')) limit=$limit owner=$owner"
    end
    Servo.@DELETE r "/items/{id}" public format=Servo.TextFormat() function rmitem(id::Int)
        nothing
    end
    Servo.@POST r "/echo" public format=Servo.TextFormat() function echo(msg::String)
        Servo.Response(201, uppercase(msg))
    end
    Servo.@QUERY r "/search" public format=Servo.TextFormat() function search(needle::String; limit::Int=3)
        "found:$needle:$limit"
    end
    Servo.@GET r "/widgets/{id}" public function getwidget(id::Int; dry::Bool=false)
        (; ok = !dry, id, n = 2)
    end
    Servo.@GET r "/secret" TrimAuth("open-sesame") format=Servo.TextFormat() function secret()
        Servo.principal() isa String && Servo.request() isa TrimRequest ? "granted" : "no-context"
    end
    Servo.@GET r "/pub" public format=Servo.TextFormat() function pub()
        "ok"
    end
    Servo.@GET r "/docs/{page...}" public format=Servo.TextFormat() function docpage(page::String)
        "doc:$page"
    end
    # typing the request argument is what keeps the raw-handler call statically
    # resolvable under trim (untyped handlers work, at the cost of one dynamic call)
    Servo.register!(r, :GET, "/mirror/{id}/**", function mirror(req::TrimRequest)
        Servo.request() === req || return Servo.Response(500, "wrong request")
        Servo.Response(200, "mirror:" * Servo.pathparams()[:id])
    end; auth=Servo.Public())
    return r
end

# requests dispatch through matchroute results: Endpoint is a concrete struct,
# so this needs no per-endpoint typed references
function _getep(r::Servo.Router, method::String, path::String)
    m = Servo.matchroute(r, method, path)
    m isa Tuple || error("no route for $method $path")
    return m[1], m[2]
end

function _trim_routing(r::Servo.Router)::Nothing
    ep, pp = _getep(r, "GET", "/items/42")
    _trim_assert(ep.name == "getitem", "route name")
    _trim_assert(pp[:id] == "42", "path param captured")
    _trim_assert(Servo.matchroute(r, "PUT", "/items/42") === :method_not_allowed, "405")
    _trim_assert(Servo.matchroute(r, "GET", "/nope") === nothing, "404")
    _trim_assert(length(r.endpoints) == 9, "route table size")

    # catch-all: binds the slash-joined remainder, needs at least one segment
    ep, pp = _getep(r, "GET", "/docs/guide/intro")
    _trim_assert(pp[:page] == "guide/intro", "catch-all capture")
    resp = Servo.handle(ep, pp, TrimRequest())
    _trim_assert(resp.status == 200 && resp.body == "doc:guide/intro", "catch-all bound value")
    _trim_assert(Servo.matchroute(r, "GET", "/docs") === nothing, "catch-all needs a segment")

    # raw handler: pathparams() ambient access, Response passthrough
    ep, pp = _getep(r, "GET", "/mirror/9/x/y")
    resp = Servo.handle(ep, pp, TrimRequest())
    _trim_assert(resp.status == 200 && resp.body == "mirror:9", "raw handler")
    _trim_assert(Servo.request() === nothing, "raw request scope cleared")
    _trim_assert(isempty(Servo.pathparams()), "raw path scope cleared")
    return nothing
end

function _trim_binding(r::Servo.Router)::Nothing
    ep, _ = _getep(r, "GET", "/items/7")
    resp = Servo.handle(ep, Dict(:id => "7"),
        TrimRequest(; query = ["owner" => "jake", "verbose" => "true", "tags" => "a,b", "limit" => "3"]))
    _trim_assert(resp.status == 200, "getitem status")
    _trim_assert(resp.body == "id=7 verbose=true tags=a|b limit=3 owner=jake", "getitem body")
    resp = Servo.handle(ep, Dict(:id => "7"), TrimRequest(; query = ["owner" => "jake"]))
    _trim_assert(resp.body == "id=7 verbose=false tags= limit=nothing owner=jake", "getitem defaults")

    _expect_httperror(400, "missing required query param") do
        Servo.handle(ep, Dict(:id => "7"), TrimRequest())
    end
    _expect_httperror(400, "bad path param") do
        Servo.handle(ep, Dict(:id => "abc"), TrimRequest(; query = ["owner" => "j"]))
    end
    _expect_httperror(400, "bad query param") do
        Servo.handle(ep, Dict(:id => "7"), TrimRequest(; query = ["owner" => "j", "limit" => "many"]))
    end

    # nothing -> 204; Servo.Response passthrough; empty body -> 400
    epdel, _ = _getep(r, "DELETE", "/items/1")
    _trim_assert(Servo.handle(epdel, Dict(:id => "1"), TrimRequest()).status == 204, "204")
    epecho, _ = _getep(r, "POST", "/echo")
    resp = Servo.handle(epecho, NOPARAMS, TrimRequest(; body = "hey"))
    _trim_assert(resp.status == 201 && resp.body == "HEY", "response passthrough")
    _expect_httperror(400, "missing body") do
        Servo.handle(epecho, NOPARAMS, TrimRequest())
    end

    # the QUERY method binds a body plus query parameters
    epq, _ = _getep(r, "QUERY", "/search")
    resp = Servo.handle(epq, NOPARAMS, TrimRequest(; body = "needle", query = ["limit" => "5"]))
    _trim_assert(resp.body == "found:needle:5", "QUERY binding")
    return nothing
end

function _trim_json(r::Servo.Router)::Nothing
    _trim_assert(JSON.json(TrimWidget(1, ["x"])) == "{\"id\":1,\"tags\":[\"x\"]}", "json struct write")
    ep, _ = _getep(r, "GET", "/widgets/9")
    resp = Servo.handle(ep, Dict(:id => "9"), TrimRequest())
    _trim_assert(resp.status == 200, "json status")
    _trim_assert(resp.headers == ["Content-Type" => "application/json; charset=utf-8"], "json content type")
    _trim_assert(resp.body == "{\"ok\":true,\"id\":9,\"n\":2}", "json response")
    resp = Servo.handle(ep, Dict(:id => "9"), TrimRequest(; query = ["dry" => "true"]))
    _trim_assert(resp.body == "{\"ok\":false,\"id\":9,\"n\":2}", "json response with query")
    return nothing
end

function _trim_auth_and_ratelimit(r::Servo.Router)::Nothing
    ep, _ = _getep(r, "GET", "/secret")
    resp = Servo.handle(ep, NOPARAMS, TrimRequest(; query = ["key" => "open-sesame"]))
    _trim_assert(resp.body == "granted", "scoped principal and request")
    _trim_assert(Servo.principal() === nothing, "principal cleared outside request")
    _trim_assert(Servo.request() === nothing, "request cleared outside request")
    _trim_assert(isempty(Servo.pathparams()), "path params cleared outside request")
    _expect_httperror(401, "bad credentials") do
        Servo.handle(ep, NOPARAMS, TrimRequest(; query = ["key" => "wrong"]))
    end

    rl = Servo.RateLimiter(; rps = 10.0, burst = 2.0)
    _trim_assert(Servo.allow!(rl, ("a", "1.2.3.4")), "bucket 1")
    _trim_assert(Servo.allow!(rl, ("a", "1.2.3.4")), "bucket 2")
    _trim_assert(!Servo.allow!(rl, ("a", "1.2.3.4")), "bucket exhausted")
    _trim_assert(Servo.allow!(rl, ("a", "5.6.7.8")), "separate key")

    pub, _ = _getep(r, "GET", "/pub")
    Servo.PUBLIC_RATE_LIMITER[] = Servo.RateLimiter(; rps = 0.1, burst = 1.0)
    try
        _trim_assert(Servo.handle(pub, NOPARAMS, TrimRequest(; ip = "1.2.3.4")).status == 200, "public ok")
        _expect_httperror(429, "public rate limited") do
            Servo.handle(pub, NOPARAMS, TrimRequest(; ip = "1.2.3.4"))
        end
    finally
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end
    return nothing
end

function _trim_validation()::Nothing
    # explicit stub binders: hand-constructed endpoints default to the
    # reflective GenericBinder, which is deliberately not trim-verifiable
    stub = Servo.Binder((fmt, pp, q, b) -> nothing)
    _expect_argumenterror("missing auth") do
        Servo.Endpoint(; method = :GET, path = "/x", target = () -> 1,
            binder = stub, format = Servo.TextFormat())
    end
    _expect_argumenterror("body arg on GET") do
        Servo.Endpoint(; method = :GET, path = "/x", target = () -> 1,
            params = [Servo.Param(:b, String, :body)], binder = stub,
            auth = Servo.Public(), format = Servo.TextFormat())
    end
    _expect_argumenterror("path/arg mismatch") do
        Servo.Endpoint(; method = :GET, path = "/a/{id}", target = () -> 1,
            binder = stub, auth = Servo.Public(), format = Servo.TextFormat())
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
    r = _buildapp()
    _trim_routing(r)
    _trim_binding(r)
    _trim_json(r)
    _trim_auth_and_ratelimit(r)
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
