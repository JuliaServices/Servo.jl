"""
    Servo.Param(name, type, source, required)

Describes one argument of an endpoint's target function and where its value comes
from: `:path` (a `{name}` segment), `:query` (a query/request parameter, passed as
a keyword argument), or `:body` (the request payload, deserialized with the
endpoint's `Format`). `required=false` is only meaningful for `:query` params —
when absent from the request the keyword is simply not passed, so the function's
own default applies.
"""
struct Param
    name::Symbol
    type::Type
    source::Symbol
    required::Bool

    function Param(name::Symbol, type::Type, source::Symbol, required::Bool=true)
        source in (:path, :query, :body) ||
            throw(ArgumentError("invalid param source `$source` for `$name`; expected :path, :query, or :body"))
        return new(name, type, source, required)
    end
end

const METHODS = (:GET, :POST, :PUT, :DELETE, :PATCH, :QUERY)
const BODYLESS_METHODS = (:GET, :DELETE)  # QUERY carries a request body by design

"""
    Servo.Endpoint(; method, path, target, params=Param[], auth, name="", format=JSONFormat())

One unit of exposed functionality: an addressable `method` + `path` routed to a
`target` function, with `params` describing how transport data binds to the
function's arguments, a mandatory `auth` scheme, and a `format` for payload
(de)serialization.

Endpoints are plain, introspectable values — the route table is real data that
tooling (docs, API catalogs, client/tool generation) can walk.

All structural validation happens here, at construction time (i.e. when your app
loads): unknown methods, malformed paths, path/argument mismatches, misplaced body
arguments, missing auth, and unavailable formats all throw `ArgumentError`
immediately.

The `binder` is the callable that actually extracts/coerces arguments and invokes
`target`: `binder(format, pathparams, query, body) -> result`. The endpoint
macros generate a statically-typed binder from the function signature; endpoints
constructed by hand default to the reflective [`GenericBinder`](@ref).

Requests are served through `handler`, a type-erased [`HandlerFn`](@ref) built
at construction that closes over the endpoint's concrete binder/auth/format.
This makes `Endpoint` itself concrete (no type parameters — a `Vector{Endpoint}`
route table is fully typed, and dispatching a router match involves no dynamic
call), while the pipeline inside each handler stays statically compiled against
that endpoint's types. One consequence: **endpoints must be constructed at
runtime** (registration belongs in `Servo.@init` / your module's `__init__`),
since the handler captures a function pointer that would go stale if baked into
a precompile image.
"""
struct Endpoint
    name::String
    method::Symbol
    path::String
    segments::Vector{Union{String, Symbol}}
    params::Vector{Param}
    target::Any   # introspection only; requests are invoked through `handler`
    binder::Any   # introspection/inference only; wrapped inside `handler`
    auth::AuthScheme
    format::Format
    handler::HandlerFn
end

"""
    GenericBinder(target, params)

The default endpoint binder: interprets `params` at request time, collecting
positional arguments into a `Vector{Any}` and keywords into pairs, then splats
into `target`. Fully general (any `Vector{Param}`), but dynamically dispatched —
the endpoint macros generate a static binder instead.
"""
struct GenericBinder
    target::Any
    params::Vector{Param}
end

"""
    Binder(f)

Wrapper for a binder callable `f(format, pathparams, query, body) -> result`.
Deliberately not a `Function` subtype: bare closures passed through keyword
arguments get de-specialized by Julia's `::Function` heuristic, which would make
the endpoint's handler construction dynamically dispatched (and juliac/trim
unverifiable); wrapping preserves the concrete type end to end.
"""
struct Binder{F}
    f::F
end
(b::Binder)(fmt, pathparams, query, body) = b.f(fmt, pathparams, query, body)

function Endpoint(; method::Symbol, path::AbstractString, target,
                    params::Vector{Param}=Param[], auth=nothing, binder=nothing,
                    name::AbstractString="", format::Format=JSONFormat())
    auth === nothing && throw(ArgumentError(
        "endpoint `$method $path` does not declare an auth scheme: pass `auth=Servo.Public()` " *
        "to explicitly expose it without authentication, or provide a `Servo.AuthScheme`"))
    auth isa AuthScheme || throw(ArgumentError(
        "endpoint `$method $path`: `auth` must be a Servo.AuthScheme; got $(typeof(auth))"))
    method in METHODS || throw(ArgumentError(
        "endpoint `$method $path`: unsupported method; expected one of $(join(METHODS, ", "))"))
    checkformat(format)
    segments = parsepattern(path)
    validateparams(method, path, segments, params)
    nm = isempty(name) ? "$method $path" : String(name)
    b = binder === nothing ? GenericBinder(target, params) :
        (binder isa Binder || binder isa GenericBinder) ? binder : Binder(binder)
    handler = HandlerFn(RequestHandler(nm, b, auth, format))
    return Endpoint(nm, method, String(path), segments, params, target, b, auth, format, handler)
end

# "/users/{id}/orders" -> ["users", :id, "orders"]
function parsepattern(path::AbstractString)
    startswith(path, "/") || throw(ArgumentError("endpoint path must start with '/': `$path`"))
    segments = Union{String, Symbol}[]
    for seg in split(path, '/'; keepempty=false)
        m = match(r"^\{(\w+)\}$", seg)
        if m !== nothing
            s = Symbol(m.captures[1])
            s in segments && throw(ArgumentError("duplicate path parameter `{$s}` in `$path`"))
            push!(segments, s)
        elseif occursin('{', seg) || occursin('}', seg)
            throw(ArgumentError(
                "malformed segment `$seg` in `$path`: a path parameter must be a full segment like `{name}`"))
        else
            push!(segments, String(seg))
        end
    end
    return segments
end

function validateparams(method::Symbol, path::AbstractString, segments, params::Vector{Param})
    placeholders = Symbol[s for s in segments if s isa Symbol]
    pathnames = [p.name for p in params if p.source == :path]
    for s in placeholders
        s in pathnames || throw(ArgumentError(
            "`$method $path`: path parameter `{$s}` has no matching function argument"))
    end
    for p in pathnames
        p in placeholders || throw(ArgumentError(
            "`$method $path`: argument `$p` is marked as a path parameter but the path has no `{$p}` segment"))
    end
    bodyidxs = findall(p -> p.source == :body, params)
    if !isempty(bodyidxs)
        length(bodyidxs) > 1 && throw(ArgumentError(
            "`$method $path` declares more than one body argument " *
            "($(join((params[i].name for i in bodyidxs), ", "))); " *
            "only the final positional argument may bind the request body"))
        bodyidx = only(bodyidxs)
        method in BODYLESS_METHODS && throw(ArgumentError(
            "`$method $path`: argument `$(params[bodyidx].name)` does not match a path parameter, " *
            "so it would bind the request body, but $method requests have no body; " *
            "did you misspell a path parameter, or mean to make it a keyword (query) argument?"))
        lastpositional = findlast(p -> p.source in (:path, :body), params)
        bodyidx == lastpositional || throw(ArgumentError(
            "`$method $path`: the body argument `$(params[bodyidx].name)` must be the final positional argument"))
    end
    return
end
