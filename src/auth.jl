"""
    Servo.AuthScheme

Abstract supertype for endpoint authentication schemes. **Every endpoint must
declare one** — either a real scheme or an explicit [`Public()`](@ref) — at
registration time; an endpoint with no auth declaration is an error when the app
loads, not a surprise at request time.

Interface (implement for a concrete scheme `S`):

    Servo.authenticate(scheme::S, request) -> principal | nothing

Inspect the transport request's credentials (headers, tokens, …) and return a
non-`nothing` "principal" — any value your app finds useful (user id, claims,
context struct). Handlers retrieve it with `Servo.principal()`. Returning
`nothing` produces a 401 response; throw [`HTTPError`](@ref) for anything more
specific (e.g. 403).

Authorization (roles/permissions/entity access) is deliberately *not* part of this
contract yet; check it in handlers for now.
"""
abstract type AuthScheme end

function authenticate end

"""
    Public()

Explicitly marks an endpoint as publicly accessible with **no** authentication.
Requiring this to be spelled out is the point: an endpoint is never accidentally
public because of where it happened to be registered. Public endpoints get Servo's
default per-client rate limiting when the app is started via `Servo.run!`.
"""
struct Public <: AuthScheme end

# Ambient per-request state: ScopedValues, so the context propagates into tasks
# spawned inside a handler. (Note: Base's ScopedValues scope storage is not yet
# juliac --trim=safe verifiable — a known upstream limitation the trim test
# harness allowlists until a Julia release fixes it.)
const PRINCIPAL = ScopedValue{Any}(nothing)
const REQUEST = ScopedValue{Any}(nothing)
const PATHPARAMS = ScopedValue{Dict{Symbol, String}}(Dict{Symbol, String}())

"""
    Servo.principal()

The principal returned by the current endpoint's `authenticate`, or `nothing` on
public endpoints. Only meaningful inside a handler call.
"""
principal() = PRINCIPAL[]

"""
    Servo.request()

The raw transport request currently being handled (e.g. an `HTTP.Request`), or
`nothing` outside a handler call.
"""
request() = REQUEST[]

"""
    Servo.pathparams() -> Dict{Symbol, String}

The path parameters captured by the matched route pattern, exactly as they
appeared in the request path. Bound endpoints receive these as typed function
arguments already; this accessor exists for raw handlers (registered via
`register!(router, method, path, handler; ...)`), where no binding happens.
"""
pathparams() = PATHPARAMS[]
