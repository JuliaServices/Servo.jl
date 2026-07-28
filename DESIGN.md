# Servo 2.0 design

Servo is an **application driver**: you have a Julia package that does something
useful (the "domain" layer), and Servo turns it into a running service that
others can call. This document describes the 2.0 interface, rebuilt top-down from
the lessons of three bottoms-up implementations (Servo 1.x, Roam, league-easy).

## Principles

1. **Explicit over ambient.** An endpoint's routing, argument binding, auth, and
   serialization are all declared *at the endpoint*, not implied by which global
   router it happened to be registered on. The failure mode this kills: an
   endpoint that is accidentally public.
2. **The route table is data.** `Endpoint` and `Router` are plain, introspectable
   values (method, path, typed params, auth scheme, format). API catalogs, docs,
   client/MCP tool generation can walk them instead of being hand-maintained.
3. **Fail at load time.** Structural mistakes — missing auth, path/argument
   mismatches, a format whose implementation isn't loaded — throw when the app
   *loads* (macro expansion / endpoint construction), never on the first request.
4. **Small core, open seams.** The core defines interfaces in terms of plain
   Julia; concrete serialization (JSON) plugs in through a package extension, and
   transports plug in through a three-function accessor interface.
5. **Minimal dependencies.** Servo's only real dependency is `Figgy` (config).
   Both `HTTP` (the flagship transport, extension `ServoHTTPExt`) and `JSON`
   (the default format, extension `ServoJSONExt`) are weak dependencies — an app
   does `using Servo, HTTP, JSON`.
6. **Trim-compilable core.** juliac `--trim=safe` must be able to verify the
   core request path (league-easy's deployment constraint). This is enforced by
   a JuliaC trim workload in the test suite and shaped several choices below.

## The layer model

An endpoint invocation crosses four independently-pluggable concerns:

```
        ┌────────────────────────────────────────────────────────┐
request │ Transport   how bytes arrive/leave    (HTTP, TCP, gRPC)│
   │    ├────────────────────────────────────────────────────────┤
   ▼    │ Routing     which endpoint?           (method + path)  │
        ├────────────────────────────────────────────────────────┤
        │ Auth        who is calling?           (AuthScheme)     │
        ├────────────────────────────────────────────────────────┤
        │ Binding     transport data → args     (Params + Format)│
        ├────────────────────────────────────────────────────────┤
        │ Domain      your function             (plain Julia)    │
        └────────────────────────────────────────────────────────┘
```

The generic pipeline (`Servo.handle`) is transport-independent:

```
authenticate (or rate-limit if Public)
→ bind(endpoint, pathparams, request) → (args, kwargs)
→ endpoint.target(args...; kwargs...)
→ toresponse: Servo.Response passthrough | nothing → 204 | value → serialize(format)
```

## Core model

```julia
struct Endpoint{B, A <: AuthScheme, S <: Format}
    name::String                            # e.g. "simulate" (the function name)
    method::Symbol                          # :GET, :POST, :PUT, :DELETE, :PATCH
    path::String                            # "/v1/users/{id}"
    segments::Vector{Union{String, Symbol}} # parsed pattern; Symbols are captures
    params::Vector{Param}                   # name, type, source, required
    target::Any                             # the domain function (introspection)
    binder::B                               # (format, pathparams, req) -> result
    auth::A                                 # mandatory
    format::S                               # payload (de)serialization
end
```

Requests are invoked through the `binder`. The endpoint macros *generate* a
binder from the function signature with every parameter type as a literal `Type`
argument, so extraction, coercion, deserialization, and the final call all
dispatch statically — this is what makes the request path trim-verifiable (and
fast). Hand-constructed endpoints fall back to a reflective `GenericBinder` that
interprets `params` dynamically at request time.

`Param.source` is one of `:path`, `:query`, `:body`. The binding convention
(derived from the function signature by the `@GET`/`@POST`/… macros):

- positional argument whose name matches a `{segment}` → path parameter, coerced
  from its string form to the declared type (`Int`, `Float64`, `Bool`,
  `Vector{T}` via comma-split, `Union{Nothing,T}`, anything with
  `parse(T, ::String)`);
- the final positional argument *not* matching a path segment → the request
  body, deserialized via the endpoint's `Format` (`POST`/`PUT`/`PATCH` only —
  a stray body arg on `GET` is a load-time error, since it's almost always a
  misspelled path param);
- keyword arguments → query parameters, coerced like path params. **Keywords
  without defaults are required** (400 when absent); with defaults, an absent
  query param simply isn't passed so the function's own default applies.

Coercion failures, missing required params, and malformed bodies are all
`HTTPError(400, ...)` naming the offending parameter — never a raw string handed
to your function (a 1.x bug class).

### Return protocol

A handler may return:

- any value → serialized with the endpoint's format, status 200;
- `nothing` → 204 No Content;
- `Servo.Response(status, body; headers)` → passed through verbatim (201/302/
  custom content types) — non-trivial endpoints no longer need to abandon the
  macros (the Roam limitation);
- or throw `Servo.HTTPError(status, msg)` (helpers: `badrequest`, `unauthorized`,
  `forbidden`, `notfound`). Anything else thrown logs the backtrace and returns a
  sanitized 500.

Errors serialize into a stable envelope with the endpoint's format:
`{"error": {"message": ..., "code": ...}}`.

## Seam 1: Format (serialization)

```julia
abstract type Format end
serialize(f, value)             -> String | Vector{UInt8}
deserialize(f, ::Type{T}, body) -> T
mime(f)                         -> String
```

`JSONFormat()` is the *marker* (defined dep-free in core, and the default for
endpoints); its implementation lives in the `ServoJSONExt` package extension,
active when JSON.jl is loaded. Constructing a JSON endpoint without JSON loaded
is an immediate `ArgumentError` telling you the fix. `TextFormat()` is a complete
zero-dep reference implementation (and what the builtin `/status`, `/version`
endpoints use).

Adding e.g. protobuf or MessagePack = a subtype + three methods, in another
extension or a user package.

## Seam 2: Transport

A transport teaches Servo to read its request type with three accessors —

```julia
Servo.rawbody(req)   -> bytes | string | nothing
Servo.rawquery(req)  -> iterable of String => String pairs
Servo.clientip(req)  -> anything hashable (rate-limit key) | nothing
```

— then drives `matchroute` + `handle` itself and translates `Servo.Response` /
`HTTPError` onto its wire. The HTTP implementation ([src/http.jl](src/http.jl))
is ~100 lines; the test suite contains a second, ~10-line mock transport that
exercises the whole pipeline without HTTP.

### How other implementations would look

- **gRPC**: routing by service/method name rather than path — register endpoints
  with a path like `/pkg.Service/Method` (no captures); `rawbody` returns the
  message bytes; a `ProtobufFormat <: Format` deserializes into the generated
  struct types; `rawquery` returns metadata pairs. Status codes map from
  `HTTPError` (400→INVALID_ARGUMENT, 401→UNAUTHENTICATED, 429→RESOURCE_EXHAUSTED).
- **JSON-RPC (single-POST dispatch)**: the transport parses `{method, params, id}`,
  synthesizes a route lookup on `method`, presents named `params` via `rawquery`
  and positional ones via `rawbody`, and wraps results/errors in the JSON-RPC
  envelope. Same endpoints, no HTTP semantics assumed.
- **Raw TCP + MessagePack**: a framed protocol where each frame carries
  (path, query pairs, payload); implement the three accessors over the frame
  struct, serve with a `Sockets.accept` loop calling `handle`.

The seam deliberately does *not* abstract response streaming, server push, or
transport-specific auth material beyond "the request object" — those can extend
the interface when a real second transport lands, rather than being speculated
now.

## Auth

```julia
abstract type AuthScheme end
authenticate(scheme, request) -> principal | nothing   # nothing ⇒ 401
struct Public <: AuthScheme end                        # explicit opt-out
```

**Every endpoint must declare `auth`.** The macros accept the literal `public`
(reads well, becomes `Public()`) or any `AuthScheme` value; omitting it errors at
macro-expansion time, i.e. when the app package is loaded/precompiled. The
`Endpoint` constructor enforces the same for non-macro registration.

- The *principal* is whatever `authenticate` returns — a user id, JWT claims, a
  rich context struct. Handlers read it with `Servo.principal()` (and the raw
  request with `Servo.request()`) — ambient per-request state keyed by the
  current task. (Deliberately not `Base.ScopedValues`: its HAMT scope storage is
  keyed by an abstract type juliac trim cannot verify. Tradeoff: the context
  does not propagate into tasks spawned inside a handler.)
- `Public` endpoints skip authentication but get the default **rate limiter**
  installed by `run!`: a token bucket keyed by (endpoint, client IP), configured
  via `public_ratelimit_rps` / `public_ratelimit_burst` (defaults 5/20).
- Phase 2 (deliberately not designed yet): concrete schemes (JWT/OIDC verify, API
  keys, HMAC sessions), an authorization layer (roles/permissions), and a
  context-loading seam like Roam's `AUTH_CONTEXT_LOADER`. The `authenticate`
  contract is the stable base all of that builds on.

## Declaring endpoints

```julia
module Soleil
using Servo, HTTP, JSON, Solar

Servo.@init begin
    Servo.@POST "/v1/simulate" public function simulate(spec::Solar.SimulationConfig; year::Int=2026)
        return Solar.simulate(spec; year)
    end

    Servo.@GET "/v1/position/{lat}/{lon}" public function position(lat::Float64, lon::Float64; hour::Int=12)
        return Solar.solar_position(Solar.Location(lat, lon), hour)
    end
end

run!(profile=""; kw...) = Servo.run!("Soleil", profile; kw...)
run(profile=""; kw...) = Servo.run("Soleil", profile; kw...)

end
```

`Servo.@init` wraps the registrations in the module's `__init__` (guarded against
precompilation) — registration is a runtime side effect and must happen at load
time. Macros default to the global `Servo.ROUTER`; pass an explicit first
argument (`Servo.@GET myrouter "/path" ...`) for isolated routers (tests, or
multiple apps in one process). `format=SomeFormat()` overrides the JSON default
per endpoint.

## Running an app

```julia
Servo.run!(name, profile; router, host, port, configdir, configs, accesslog, log)
Servo.run(...)   # run! + wait for SIGINT, then clean shutdown
```

`run!`:

1. loads config via Figgy, weakest → strongest: `config.toml` → env
   (`PROFILE`/`PORT`/`VERSION` only) → program args (`--key=value`) → `configs`
   kwarg → explicit `profile` argument → `config-<profile>.toml` →
   `.config-<profile>.toml` (secrets, gitignored). `Servo.config("a.b")` reads it
   anywhere, with dotted-key traversal;
2. installs the public rate limiter;
3. registers builtin `GET /status` ("ok") and `GET /version` (the `version`
   config key) unless the app already claimed those routes;
4. serves HTTP with the error-envelope handler, access logging, and — **only on
   the `local` profile** — permissive CORS (including OPTIONS preflight,
   centrally, ending 1.x's per-route OPTIONS registration wart).

## Fixed from the 1.x lineage

- **Concurrency bug**: 1.x shared one `args = []` buffer per route across
  concurrent requests; binding is now pure per-request.
- **200-only responses** → the return protocol above.
- **Silent coercion fallback** (failed parse returned the raw string; untyped
  args got regex-guessed types) → typed 400s; untyped params are always `String`.
- **No error middleware** → uniform envelope + sanitized 500s on every route.
- **OPTIONS/CORS per-route hacks** → handled once in the CORS middleware.
- **Public-by-router-choice** → mandatory per-endpoint auth declaration.
- **Opaque route table** → `Endpoint`/`Router` are inspectable data.
- **Positional-with-default args** treated as query params (ambiguous with
  optional positional) → rejected at expansion; query params are keyword-only.

## Trim compilation

`test/trim_compile_tests.jl` compiles `test/servo_trim_safe.jl` with JuliaC
(`--trim=safe`, zero-error/zero-warning budget, same harness as
Figgy/JSON/StructUtils) and runs the resulting binary. The workload exercises
endpoint declaration + validation, routing, statically-bound coercion, auth,
rate limiting, TextFormat + JSON serialization, and Figgy config loading over a
mock transport. Scope notes:

- The **HTTP transport is excluded**: released HTTP 1.x can't live in a
  trim=safe image (MbedTLS/OpenSSL `__init__` cfunctions) — which is exactly why
  it's a package extension. When the Reseau-based HTTP 2.x lands, a server
  workload can be added.
- **JSON body materialization is excluded**: typed `JSON.parse` is a known open
  trim gap in JSON.jl itself (see JSON's own trim entrypoints test); `JSON.json`
  writing is covered. Servo's body-binding path is verified via `TextFormat`.
- Trim-shaped code choices: generated static binders, `target::Any` (uncalled
  `Function`-typed args de-specialize and force dynamic `apply_type`), explicit
  lock/unlock instead of closure-capturing `lock() do` in `matchroute`,
  task-keyed request context instead of ScopedValues, typed rate-limiter keys,
  and one-concrete-source-per-call Figgy loading.

## Deliberately deferred

Resource lifecycle hooks (DB pools etc.), background/scheduled task registry,
metrics/observability, streaming responses (SSE), config schemas/validation,
concrete auth schemes and authorization, request-id propagation.
