using Test, Servo, JSON
import HTTP

# ── a minimal second transport, defined in ~10 lines: used to test the generic
# pipeline (routing, binding, auth, formats) without HTTP in the loop
struct TestRequest
    query::Vector{Pair{String, String}}
    body::Union{Nothing, String, Vector{UInt8}}
    ip::Union{Nothing, String}
end
TestRequest(; query=Pair{String, String}[], body=nothing, ip=nothing) = TestRequest(query, body, ip)
Servo.rawquery(r::TestRequest) = r.query
Servo.rawbody(r::TestRequest) = r.body
Servo.clientip(r::TestRequest) = r.ip

# a custom auth scheme against the mock transport
struct KeyAuth <: Servo.AuthScheme
    key::String
end
Servo.authenticate(a::KeyAuth, req::TestRequest) =
    any(kv -> kv.first == "key" && kv.second == a.key, req.query) ? "user-1" : nothing

# a custom auth scheme against the HTTP transport
struct HeaderAuth <: Servo.AuthScheme
    key::String
end
Servo.authenticate(a::HeaderAuth, req::HTTP.Request) =
    HTTP.header(req, "X-Api-Key", "") == a.key ? "api-user" : nothing

struct Widget
    id::Int
    tags::Vector{String}
end

# eval an expression, unwrapping LoadError so macro-expansion errors are inspectable
function evalerror(expr)
    try
        Base.eval(@__MODULE__, expr)
        return nothing
    catch e
        while e isa LoadError
            e = e.error
        end
        return e
    end
end

const NOPARAMS = Dict{Symbol, String}()

@testset "Servo" begin

@testset "endpoint validation" begin
    ok(; kw...) = Servo.Endpoint(; method=:GET, path="/x", target=() -> 1,
                                   auth=Servo.Public(), format=Servo.TextFormat(), kw...)
    @test ok() isa Servo.Endpoint

    # auth is mandatory and must be an AuthScheme
    e = @test_throws ArgumentError Servo.Endpoint(; method=:GET, path="/x", target=() -> 1)
    @test occursin("auth", e.value.msg)
    @test_throws ArgumentError Servo.Endpoint(; method=:GET, path="/x", target=() -> 1, auth=:public)

    # method/path validation
    @test_throws ArgumentError ok(; method=:FETCH)
    @test_throws ArgumentError ok(; path="no-slash")
    @test_throws ArgumentError ok(; path="/a/{x}/{x}", params=[Servo.Param(:x, Int, :path)])
    @test_throws ArgumentError ok(; path="/a/b{x}")

    # path params must line up with placeholders, both directions
    @test_throws ArgumentError ok(; path="/a/{id}")
    @test_throws ArgumentError ok(; params=[Servo.Param(:id, Int, :path)])

    # body args: only one, only last, not on GET/DELETE
    @test_throws ArgumentError ok(; params=[Servo.Param(:b, String, :body)])  # GET
    @test_throws ArgumentError Servo.Endpoint(; method=:POST, path="/x", target=identity,
        auth=Servo.Public(), format=Servo.TextFormat(),
        params=[Servo.Param(:a, String, :body), Servo.Param(:b, String, :body)])
    @test_throws ArgumentError Servo.Endpoint(; method=:POST, path="/x/{id}", target=identity,
        auth=Servo.Public(), format=Servo.TextFormat(),
        params=[Servo.Param(:b, String, :body), Servo.Param(:id, Int, :path)])

    @test_throws ArgumentError Servo.Param(:x, Int, :header)
end

@testset "macro expansion" begin
    # missing auth is an expansion-time error with a helpful message
    e = evalerror(:(Servo.@GET "/noauth" function noauth() end))
    @test e isa ArgumentError && occursin("auth", e.msg)
    # positional defaults are rejected: query params are keyword-only
    e = evalerror(:(Servo.@GET "/posdefault" public function f(x=1) end))
    @test e isa ArgumentError && occursin("keyword", e.msg)
    # path must be a string literal
    e = evalerror(:(Servo.@GET 42 public function f() end))
    @test e isa ArgumentError
    # anonymous functions are rejected
    e = evalerror(:(Servo.@GET "/anon" public () -> 1))
    @test e isa ArgumentError && occursin("named function", e.msg)
end

@testset "router" begin
    r = Servo.Router()
    tep(method, path; params=Servo.Param[]) = Servo.register!(r, Servo.Endpoint(;
        method, path, target=() -> 1, params, auth=Servo.Public(), format=Servo.TextFormat()))
    tep(:GET, "/users/{id}"; params=[Servo.Param(:id, Int, :path)])
    tep(:GET, "/users/me")
    tep(:PUT, "/users/{id}"; params=[Servo.Param(:id, Int, :path)])

    m = Servo.matchroute(r, "GET", "/users/42")
    @test m isa Tuple && m[2] == Dict(:id => "42")
    # literal segment beats a parameter capture
    m = Servo.matchroute(r, "GET", "/users/me")
    @test m isa Tuple && m[1].path == "/users/me"
    @test Servo.matchroute(r, "GET", "/nope") === nothing
    @test Servo.matchroute(r, "POST", "/users/42") === :method_not_allowed
    @test Servo.matchroute(r, "GET", "/users/1/2") === nothing

    # re-registering the same shape replaces (with a warning), even with a renamed param
    n = length(r.endpoints)
    @test_logs (:warn, r"replacing") Servo.register!(r, Servo.Endpoint(;
        method=:GET, path="/users/{uid}", target=() -> 2,
        params=[Servo.Param(:uid, Int, :path)], auth=Servo.Public(), format=Servo.TextFormat()))
    @test length(r.endpoints) == n

    # the route table is introspectable data
    @test all(ep -> ep.auth isa Servo.Public, r.endpoints)
    @test Set(ep.method for ep in r.endpoints) == Set([:GET, :PUT])
end

@testset "wildcards & catch-alls" begin
    r = Servo.Router()
    tep(method, path; params=Servo.Param[]) = Servo.register!(r, Servo.Endpoint(;
        method, path, target=() -> 1, params, auth=Servo.Public(), format=Servo.TextFormat()))

    # `*` matches any single segment, binds nothing
    tep(:GET, "/files/*/meta")
    m = Servo.matchroute(r, "GET", "/files/anything/meta")
    @test m isa Tuple && isempty(m[2])
    @test Servo.matchroute(r, "GET", "/files/a/b/meta") === nothing

    # `{name...}` matches the remainder (at least one segment), binds it joined
    tep(:GET, "/files/{path...}"; params=[Servo.Param(:path, String, :path)])
    m = Servo.matchroute(r, "GET", "/files/a/b/c.txt")
    @test m isa Tuple && m[2] == Dict(:path => "a/b/c.txt")
    m = Servo.matchroute(r, "GET", "/files/solo")
    @test m isa Tuple && m[2] == Dict(:path => "solo")
    @test Servo.matchroute(r, "GET", "/files") === nothing

    # anonymous `**`: matches the remainder, binds nothing
    tep(:GET, "/pub/**")
    m = Servo.matchroute(r, "GET", "/pub/x/y/z")
    @test m isa Tuple && isempty(m[2])
    @test Servo.matchroute(r, "GET", "/pub") === nothing

    # grammar/validation errors
    @test_throws ArgumentError tep(:GET, "/a/**/b")                       # catch-all not final
    @test_throws ArgumentError tep(:GET, "/a/{x...}/b"; params=[Servo.Param(:x, String, :path)])
    @test_throws ArgumentError tep(:GET, "/a/{x}/{x...}"; params=[Servo.Param(:x, String, :path)])
    @test_throws ArgumentError tep(:GET, "/a/{x...}"; params=[Servo.Param(:x, Int, :path)])  # catch-all must be String
    @test_throws ArgumentError tep(:GET, "/a/b{x}c")

    # shape conflicts: `{id}` vs `*` and `{rest...}` vs `**` match the same requests
    n = length(r.endpoints)
    @test_logs (:warn, r"replacing") tep(:GET, "/files/{f}/meta"; params=[Servo.Param(:f, String, :path)])
    @test_logs (:warn, r"replacing") tep(:GET, "/pub/{rest...}"; params=[Servo.Param(:rest, String, :path)])
    @test length(r.endpoints) == n

    # macro form: a named catch-all binds like any other path parameter
    ep = Servo.@GET r "/docs/{page...}" public format=Servo.TextFormat() function docpage(page::String)
        "doc:$page"
    end
    @test [(p.name, p.source, p.type) for p in ep.params] == [(:page, :path, String)]
    m = Servo.matchroute(r, "GET", "/docs/guide/intro")
    @test m isa Tuple
    resp = Servo.handle(m[1], m[2], TestRequest())
    @test resp.status == 200 && String(resp.body) == "doc:guide/intro"
end

@testset "specificity" begin
    # leftmost segment rank decides: literal > {name}/* > catch-all — and the
    # winner is independent of registration order
    function build(order)
        r = Servo.Router()
        tep(path; params=Servo.Param[]) = Servo.register!(r, Servo.Endpoint(;
            method=:GET, path, target=() -> 1, params, auth=Servo.Public(), format=Servo.TextFormat()))
        specs = Dict(
            "/a/{x}/c" => [Servo.Param(:x, String, :path)],
            "/{y}/b/c" => [Servo.Param(:y, String, :path)],
            "/a/**" => Servo.Param[],
            "/a/{x}/{z}" => [Servo.Param(:x, String, :path), Servo.Param(:z, String, :path)],
        )
        for p in order
            tep(p; params=specs[p])
        end
        return r
    end
    for order in (["/a/{x}/c", "/{y}/b/c", "/a/**", "/a/{x}/{z}"],
                  ["/a/**", "/a/{x}/{z}", "/{y}/b/c", "/a/{x}/c"])
        r = build(order)
        m = Servo.matchroute(r, "GET", "/a/b/c")
        @test m isa Tuple && m[1].path == "/a/{x}/c"      # leftmost literal wins
        m = Servo.matchroute(r, "GET", "/a/q/z")
        @test m isa Tuple && m[1].path == "/a/{x}/{z}"    # fixed-length beats catch-all
        m = Servo.matchroute(r, "GET", "/a/only")
        @test m isa Tuple && m[1].path == "/a/**"         # catch-all still catches the rest
    end
end

@testset "raw handlers" begin
    r = Servo.Router()

    # auth is not an escape hatch: raw routes must declare it too
    e = @test_throws ArgumentError Servo.register!(r, :GET, "/raw", req -> Servo.Response(200, "x"))
    @test occursin("auth", e.value.msg)

    # raw handler: gets the raw transport request, reads captures via pathparams()
    ep = Servo.register!(r, "GET", "/raw/{id}/**", function rawroute(req)
        pp = Servo.pathparams()
        Servo.Response(200, "id=$(pp[:id]) type=$(nameof(typeof(req)))")
    end; auth=Servo.Public())
    @test ep isa Servo.Endpoint
    @test ep.method == :GET   # String method accepted
    @test [(p.name, p.source) for p in ep.params] == [(:id, :path)]  # captures introspectable
    m = Servo.matchroute(r, "GET", "/raw/7/a/b")
    @test m isa Tuple
    resp = Servo.handle(m[1], m[2], TestRequest())
    @test resp.status == 200 && String(resp.body) == "id=7 type=TestRequest"
    @test Servo.pathparams() == Dict{Symbol, String}()  # ambient state cleared

    # non-Response returns: value -> serialized with the route's format; nothing -> 204
    Servo.register!(r, :GET, "/rawval", req -> "plain"; auth=Servo.Public())
    m = Servo.matchroute(r, "GET", "/rawval")
    resp = Servo.handle(m[1], m[2], TestRequest())
    @test resp.status == 200 && String(resp.body) == "plain"
    @test ("Content-Type" => "text/plain; charset=utf-8") in resp.headers
    Servo.register!(r, :GET, "/rawjson", req -> (; ok = true); auth=Servo.Public(), format=Servo.JSONFormat())
    m = Servo.matchroute(r, "GET", "/rawjson")
    resp = Servo.handle(m[1], m[2], TestRequest())
    @test String(resp.body) == "{\"ok\":true}"
    Servo.register!(r, :DELETE, "/rawnothing", req -> nothing; auth=Servo.Public())
    m = Servo.matchroute(r, "DELETE", "/rawnothing")
    @test Servo.handle(m[1], m[2], TestRequest()).status == 204

    # real auth schemes work on raw routes, and principal() is set
    Servo.register!(r, :GET, "/rawsecret", req -> "hi $(Servo.principal())"; auth=KeyAuth("sekrit"))
    m = Servo.matchroute(r, "GET", "/rawsecret")
    resp = Servo.handle(m[1], m[2], TestRequest(; query=["key" => "sekrit"]))
    @test String(resp.body) == "hi user-1"
    e = @test_throws Servo.HTTPError Servo.handle(m[1], m[2], TestRequest(; query=["key" => "nope"]))
    @test e.value.status == 401

    # public raw routes get the default rate limiting
    Servo.PUBLIC_RATE_LIMITER[] = Servo.RateLimiter(; rps=0.1, burst=1.0)
    try
        m = Servo.matchroute(r, "GET", "/rawval")
        @test Servo.handle(m[1], m[2], TestRequest(; ip="9.9.9.9")).status == 200
        e = @test_throws Servo.HTTPError Servo.handle(m[1], m[2], TestRequest(; ip="9.9.9.9"))
        @test e.value.status == 429
    finally
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end
end

@testset "binding & coercion over the mock transport" begin
    r = Servo.Router()

    ep = Servo.@GET r "/items/{id}" public format=Servo.TextFormat() function getitem(
            id::Int; verbose::Bool=false, tags::Vector{String}=String[],
            limit::Union{Nothing, Int}=nothing, owner)
        "id=$id verbose=$verbose tags=$(join(tags, '|')) limit=$limit owner=$owner"
    end
    @test ep isa Servo.Endpoint
    @test ep.name == "getitem"
    @test [p.source for p in ep.params] == [:path, :query, :query, :query, :query]
    @test ep.params[5].required  # `owner` has no default

    resp = Servo.handle(ep, Dict(:id => "7"),
        TestRequest(; query=["owner" => "jake", "verbose" => "true", "tags" => "a,b", "limit" => "3"]))
    @test resp.status == 200
    @test String(resp.body) == "id=7 verbose=true tags=a|b limit=3 owner=jake"

    # optional query params absent -> function defaults apply
    resp = Servo.handle(ep, Dict(:id => "7"), TestRequest(; query=["owner" => "jake"]))
    @test String(resp.body) == "id=7 verbose=false tags= limit=nothing owner=jake"

    # required query param missing -> 400; bad values -> 400
    e = @test_throws Servo.HTTPError Servo.handle(ep, Dict(:id => "7"), TestRequest())
    @test e.value.status == 400 && occursin("owner", e.value.message)
    e = @test_throws Servo.HTTPError Servo.handle(ep, Dict(:id => "abc"), TestRequest(; query=["owner" => "j"]))
    @test e.value.status == 400 && occursin("id", e.value.message)
    e = @test_throws Servo.HTTPError Servo.handle(ep, Dict(:id => "7"),
        TestRequest(; query=["owner" => "j", "limit" => "many"]))
    @test e.value.status == 400 && occursin("limit", e.value.message)

    # body binding: TextFormat body -> trailing String positional
    ep = Servo.@POST r "/shout" public format=Servo.TextFormat() function shout(msg::String)
        uppercase(msg)
    end
    @test [p.source for p in ep.params] == [:body]
    resp = Servo.handle(ep, NOPARAMS, TestRequest(; body="hey"))
    @test resp.status == 200 && String(resp.body) == "HEY"
    e = @test_throws Servo.HTTPError Servo.handle(ep, NOPARAMS, TestRequest())
    @test e.value.status == 400 && occursin("body", e.value.message)

    # nothing -> 204, Servo.Response passes through untouched
    ep = Servo.@DELETE r "/items/{id}" public format=Servo.TextFormat() function rmitem(id::Int)
        nothing
    end
    @test Servo.handle(ep, Dict(:id => "1"), TestRequest()).status == 204
    ep = Servo.@POST r "/created" public format=Servo.TextFormat() function created(body::String)
        Servo.Response(201, "made"; headers=["Location" => "/created/1"])
    end
    resp = Servo.handle(ep, NOPARAMS, TestRequest(; body="x"))
    @test resp.status == 201 && ("Location" => "/created/1") in resp.headers

    # the QUERY method carries a body (its trailing positional arg) plus query params
    ep = Servo.@QUERY r "/search" public format=Servo.TextFormat() function searchit(needle::String; limit::Int=2)
        "$needle/$limit"
    end
    @test ep.method == :QUERY
    @test [p.source for p in ep.params] == [:body, :query]
    resp = Servo.handle(ep, NOPARAMS, TestRequest(; body="abc", query=["limit" => "5"]))
    @test resp.status == 200 && String(resp.body) == "abc/5"

    # handler HTTPError helpers surface as-is
    ep = Servo.@GET r "/teapot" public format=Servo.TextFormat() function teapot()
        throw(Servo.HTTPError(418, "short and stout"))
    end
    e = @test_throws Servo.HTTPError Servo.handle(ep, NOPARAMS, TestRequest())
    @test e.value.status == 418
end

@testset "auth over the mock transport" begin
    r = Servo.Router()
    ep = Servo.@GET r "/whoami" KeyAuth("sekrit") format=Servo.TextFormat() function whoami()
        "principal=$(Servo.principal()) request=$(typeof(Servo.request()))"
    end
    @test ep.auth == KeyAuth("sekrit")

    resp = Servo.handle(ep, NOPARAMS, TestRequest(; query=["key" => "sekrit"]))
    @test String(resp.body) == "principal=user-1 request=TestRequest"
    # outside a request, the scoped values are back to nothing
    @test Servo.principal() === nothing && Servo.request() === nothing

    e = @test_throws Servo.HTTPError Servo.handle(ep, NOPARAMS, TestRequest(; query=["key" => "wrong"]))
    @test e.value.status == 401
end

@testset "rate limiting" begin
    rl = Servo.RateLimiter(; rps=10.0, burst=2.0)
    @test Servo.allow!(rl, ("a", "ip1"))
    @test Servo.allow!(rl, ("a", "ip1"))
    @test !Servo.allow!(rl, ("a", "ip1"))
    @test Servo.allow!(rl, ("b", "ip1"))  # separate buckets per key
    sleep(0.15)
    @test Servo.allow!(rl, ("a", "ip1"))  # refilled

    # public endpoints enforce the limiter installed by run!
    r = Servo.Router()
    ep = Servo.@GET r "/pub" public format=Servo.TextFormat() function pub() "ok" end
    Servo.PUBLIC_RATE_LIMITER[] = Servo.RateLimiter(; rps=0.1, burst=1.0)
    try
        @test Servo.handle(ep, NOPARAMS, TestRequest(; ip="1.2.3.4")).status == 200
        e = @test_throws Servo.HTTPError Servo.handle(ep, NOPARAMS, TestRequest(; ip="1.2.3.4"))
        @test e.value.status == 429
        # different client ip -> different bucket
        @test Servo.handle(ep, NOPARAMS, TestRequest(; ip="5.6.7.8")).status == 200
    finally
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end
end

@testset "JSON format extension" begin
    @test Base.get_extension(Servo, :ServoJSONExt) !== nothing
    @test Servo.mime(Servo.JSONFormat()) == "application/json; charset=utf-8"

    r = Servo.Router()
    # JSONFormat is the default; body materializes into a typed struct
    ep = Servo.@POST r "/widgets/{id}" public function makewidget(id::Int, w::Widget; dry::Bool=false)
        (; ok = !dry, echo = w, id)
    end
    @test [(p.name, p.source) for p in ep.params] == [(:id, :path), (:w, :body), (:dry, :query)]
    @test ep.format isa Servo.JSONFormat

    resp = Servo.handle(ep, Dict(:id => "9"),
        TestRequest(; body=JSON.json(Widget(9, ["red", "blue"]))))
    @test resp.status == 200
    out = JSON.parse(String(resp.body))
    @test out.ok == true && out.id == 9 && out.echo.tags == ["red", "blue"]

    # malformed body -> 400
    e = @test_throws Servo.HTTPError Servo.handle(ep, Dict(:id => "9"), TestRequest(; body="{oops"))
    @test e.value.status == 400 && occursin("malformed", e.value.message)
end

@testset "HTTP transport end-to-end" begin
    r = Servo.Router()
    Servo.@GET r "/hello/{name}" public function hello(name::String; excited::Bool=false)
        (; greeting = excited ? "HELLO $(uppercase(name))!" : "hello $name")
    end
    Servo.@POST r "/widgets" public function postwidget(w::Widget)
        (; got = w.id, n = length(w.tags))
    end
    Servo.@GET r "/secret" HeaderAuth("open-sesame") function secret()
        (; principal = Servo.principal())
    end
    Servo.@GET r "/boom" public function boom()
        error("kaboom")
    end
    Servo.@QUERY r "/find" public function findwidget(w::Widget)
        (; found = w.id, n = length(w.tags))
    end
    Servo.@GET r "/docs/{page...}" public format=Servo.TextFormat() function docpage(page::String)
        "doc:$page"
    end
    Servo.register!(r, "GET", "/mirror/**", function mirror(req)
        Servo.Response(200, HTTP.URI(req.target).path)
    end; auth=Servo.Public())
    Servo.register!(r, "GET", "/transport", function transport(req)
        Servo.Response(200, "$(req.proto_major)|$(Servo.clientip(req))")
    end; auth=Servo.Public())

    server = Servo.serve!(r; host="127.0.0.1", port=0)
    try
        port = Servo.port(server)
        base = "http://127.0.0.1:$port"
        get(url; kw...) = HTTP.get(base * url; status_exception=false, kw...)

        resp = get("/hello/world")
        @test resp.status == 200
        @test HTTP.header(resp, "Content-Type") == "application/json; charset=utf-8"
        @test JSON.parse(String(resp.body)).greeting == "hello world"
        @test JSON.parse(String(get("/hello/world?excited=true").body)).greeting == "HELLO WORLD!"

        # query param coercion failure -> 400 with the JSON error envelope
        resp = get("/hello/world?excited=maybe")
        @test resp.status == 400
        err = JSON.parse(String(resp.body)).error
        @test err.code == 400 && occursin("excited", err.message)

        # JSON body in, JSON out
        resp = HTTP.post(base * "/widgets"; body=JSON.json(Widget(5, ["a"])), status_exception=false)
        @test resp.status == 200 && JSON.parse(String(resp.body)).got == 5
        # empty body -> 400
        @test HTTP.post(base * "/widgets"; status_exception=false).status == 400

        # auth over real HTTP headers
        @test get("/secret").status == 401
        resp = get("/secret"; headers=["X-Api-Key" => "open-sesame"])
        @test resp.status == 200 && JSON.parse(String(resp.body)).principal == "api-user"

        # routing errors: plain-text envelope (no endpoint matched)
        @test get("/nope").status == 404
        @test HTTP.put(base * "/hello/world"; status_exception=false).status == 405

        # unhandled handler exception -> sanitized 500 envelope
        resp = get("/boom")
        @test resp.status == 500
        @test JSON.parse(String(resp.body)).error.message == "internal server error"
        @test !occursin("kaboom", String(resp.body))

        # the QUERY method over real HTTP, with a JSON body
        resp = HTTP.request("QUERY", base * "/find"; body=JSON.json(Widget(3, ["q"])), status_exception=false)
        @test resp.status == 200
        @test JSON.parse(String(resp.body)).found == 3

        # catch-all endpoint: slash-joined, percent-decoded per segment
        @test String(get("/docs/guide/intro").body) == "doc:guide/intro"
        @test String(get("/docs/a%20b/c").body) == "doc:a b/c"
        @test get("/docs").status == 404

        # raw handler over real HTTP
        @test String(get("/mirror/x/y").body) == "/mirror/x/y"

        # The same server accepts cleartext HTTP/2 prior knowledge. This also
        # verifies that peer-address capture remains available on an h2 stream.
        resp = HTTP.get(base * "/transport"; protocol=:h2, status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "2|127.0.0.1"
    finally
        close(server)
    end
end

@testset "run! lifecycle & config" begin
    configdir = mktempdir()
    write(joinpath(configdir, "config.toml"), """
    greeting = "base"
    port = 8080
    """)
    write(joinpath(configdir, "config-local.toml"), """
    greeting = "hello local"

    [database]
    host = "localhost"
    """)
    write(joinpath(configdir, ".config-local.toml"), """
    apikey = "shh"
    """)

    r = Servo.Router()
    Servo.@GET r "/greet" public function greet()
        (; msg = Servo.config("greeting"))
    end

    server = Servo.run!("TestApp", "local"; router=r, host="127.0.0.1", port=0,
                        configdir, configs=Dict("version" => "1.2.3"), accesslog=false, log=false)
    try
        port = Servo.port(server)
        base = "http://127.0.0.1:$port"

        # config layering: profile toml overrides base; secrets file and configs loaded
        @test Servo.profile() == "local"
        @test Servo.config("greeting") == "hello local"
        @test Servo.config("database.host") == "localhost"
        @test Servo.config("apikey") == "shh"
        @test Servo.config("missing", "fallback") == "fallback"
        @test JSON.parse(String(HTTP.get(base * "/greet").body)).msg == "hello local"

        # builtin endpoints
        @test String(HTTP.get(base * "/status").body) == "ok"
        @test String(HTTP.get(base * "/version").body) == "1.2.3"

        # local profile -> CORS on, preflight answered
        resp = HTTP.get(base * "/status")
        @test HTTP.header(resp, "Access-Control-Allow-Origin") == "*"
        resp = HTTP.request("OPTIONS", base * "/greet"; status_exception=false)
        @test resp.status == 204
        @test HTTP.header(resp, "Access-Control-Allow-Methods") != ""

        # run! installed the public rate limiter
        @test Servo.PUBLIC_RATE_LIMITER[] isa Servo.RateLimiter
    finally
        close(server)
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end

    # non-local profile: no CORS, and the configured rate limit is enforced
    r2 = Servo.Router()
    server = Servo.run!("TestApp", "prod"; router=r2, host="127.0.0.1", port=0, configdir,
                        configs=Dict("public_ratelimit_rps" => 0.1, "public_ratelimit_burst" => 2.0),
                        accesslog=false, log=false)
    try
        port = Servo.port(server)
        base = "http://127.0.0.1:$port"
        @test Servo.profile() == "prod"
        @test Servo.config("greeting") == "base"  # no config-prod.toml -> base value
        resp = HTTP.get(base * "/status"; status_exception=false)
        @test resp.status == 200
        @test HTTP.header(resp, "Access-Control-Allow-Origin") == ""
        @test HTTP.get(base * "/status"; status_exception=false).status == 200
        @test HTTP.get(base * "/status"; status_exception=false).status == 429
    finally
        close(server)
        Servo.PUBLIC_RATE_LIMITER[] = nothing
    end
end

end # @testset "Servo"

include("trim_compile_tests.jl")
