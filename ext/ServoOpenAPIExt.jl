# OpenAPI integration for Servo, in both directions. Loads automatically when
# both Servo and OpenAPI are loaded.
#
# Router -> document: `OpenAPI.document(router)` describes a Servo.Router's
# endpoints as OpenAPI, and `OpenAPI.register!(router)` additionally serves the
# document from the running app at /openapi.json (making the endpoints
# discoverable by clients and by OpenAPI.read).
#
# Document -> router: `OpenAPI.server(doc; framework = :Servo)` generates a
# server-stub module whose `register!(router, impl)` mounts typed handlers for
# every documented operation on a Servo.Router.
module ServoOpenAPIExt

using OpenAPI, Servo

# ── router -> document ───────────────────────────────────────────────────────

# "application/json; charset=utf-8" -> "application/json" (media type keys in
# OpenAPI content maps are written without parameters)
basemime(fmt::Servo.Format) = String(strip(first(split(Servo.mime(fmt), ';'))))

# Best-effort response type: infer the return type of the endpoint's generated
# binder, which carries the full typed call (including keyword arguments) and
# receives already-extracted request data, so inference is precise regardless of
# transport. Reflectively-bound endpoints (GenericBinder) and abstract inference
# results report "unknown" rather than guessing.
function inferresponse(ep::Servo.Endpoint)
    # raw-handler routes (binder === nothing) do their own request reading;
    # nothing to infer from
    (ep.binder === nothing || ep.binder isa Servo.GenericBinder) && return nothing
    ts = try
        Base.return_types(ep.binder,
            Tuple{typeof(ep.format), Dict{Symbol, String}, Dict{String, String}, Vector{UInt8}})
    catch
        return nothing
    end
    length(ts) == 1 || return nothing
    t = ts[1]
    (t === Union{} || t === Any || t <: Servo.Response) && return nothing
    return t
end

"""
    OpenAPI.operations(router::Servo.Router; skip=("openapi",)) -> Vector{OpenAPI.Operation}

Describe a router's endpoints as framework-neutral [`OpenAPI.Operation`](@ref)s:
path/query/body binding comes from each endpoint's `params`, the content type
from its `format`, the security flag from its auth scheme (`Public` or not), and
the response schema from best-effort return-type inference of its binder (raw
handlers report an unknown response). Endpoints whose name is in `skip` are
omitted (by default the `/openapi.json` discovery endpoint itself).

Path templates are rebuilt from the parsed route pattern, so a named catch-all
`/files/{rest...}` is documented as `/files/{rest}` (OpenAPI has no multi-segment
template syntax; note that a generated client percent-encodes the value, so
multi-segment values don't round-trip through generated clients). Routes with
*anonymous* wildcards (`*`/`**`) are omitted entirely — there is nothing to name
in a document.
"""
function OpenAPI.operations(router::Servo.Router; skip=("openapi",))
    ops = OpenAPI.Operation[]
    for ep in router.endpoints
        ep.name in skip && continue
        # anonymous wildcard/catch-all segments have no OpenAPI representation
        all(s -> s.kind === :literal || !isempty(s.text), ep.segments) || continue
        params = OpenAPI.Param[]
        bodytype = nothing
        for p in ep.params
            if p.source == :path
                push!(params, OpenAPI.Param(string(p.name), :path, p.type))
            elseif p.source == :query
                push!(params, OpenAPI.Param(string(p.name), :query, p.type; required=p.required))
            else
                bodytype = p.type
            end
        end
        template = isempty(ep.segments) ? "/" :
            "/" * join((s.kind === :literal ? s.text : "{$(s.text)}" for s in ep.segments), '/')
        push!(ops, OpenAPI.Operation(;
            id=ep.name, method=ep.method, path=template, params, bodytype,
            responsetype=inferresponse(ep), contenttype=basemime(ep.format),
            secured=!(ep.auth isa Servo.Public)))
    end
    return ops
end

OpenAPI.document(router::Servo.Router; skip=("openapi",), kw...) =
    OpenAPI.document(OpenAPI.operations(router; skip); kw...)

function OpenAPI.register!(router::Servo.Router; path::AbstractString="/openapi.json", kw...)
    # the document is built per request so it reflects the current route table
    target = () -> Servo.Response(200, OpenAPI.JSON.json(OpenAPI.document(router; kw...));
                                  headers=["Content-Type" => "application/json"])
    return Servo.register!(router, Servo.Endpoint(;
        name="openapi", method=:GET, path, target,
        auth=Servo.Public(), format=Servo.TextFormat()))
end

# ── document -> router: server-stub emission ────────────────────────────────

# Generated Servo server modules reach HTTP.jl (multipart parsing) through
# Servo's own dependency, so user projects only need Servo itself.
const GENERATED_SERVO_SERVER_IMPORTS = """
using Servo, JSON, OpenAPI, Base64, Dates, UUIDs
const HTTP = Servo.HTTP"""

const GENERATED_SERVO_SERVER_GLUE = raw"""
function _missing_implementations(impl)
    missing_ops = String[]
    for entry in _SERVER_OPS
        isdefined(impl, entry.invoke) || push!(missing_ops, entry.signature)
    end
    return missing_ops
end

# Servo route placeholders must be word characters; OpenAPI template names like
# {user-id} are sanitized for the route and mapped back to wire names here.
function _servo_route(entry)
    route = entry.path
    names = Pair{Symbol,String}[]
    for matched in eachmatch(r"\{([^{}]+)\}", entry.path)
        wire = String(matched.captures[1])
        sanitized = replace(wire, r"[^A-Za-z0-9_]" => "_")
        base = sanitized
        counter = 1
        while any(pair -> String(pair.first) == sanitized, names)
            counter += 1
            sanitized = string(base, '_', counter)
        end
        push!(names, Symbol(sanitized) => wire)
        route = replace(route, "{" * wire * "}" => "{" * sanitized * "}")
    end
    return route, names
end

function _servo_query(request)
    target = String(request.target)
    index = findfirst('?', target)
    return index === nothing ? "" : String(SubString(target, index + 1))
end

function _servo_multipart_parts(content_type, bytes)
    startswith(_base_media_type(content_type), "multipart/") || return nothing
    parts = HTTP.parse_multipart_form(String(content_type), bytes)
    parts === nothing && return nothing
    return [
        (
            name = String(part.name),
            filename = part.filename,
            content_type = String(part.contenttype),
            data = read(part.data),
        ) for part in parts
    ]
end

function _servo_auth(entry, auth, default_auth)
    security = entry.operation.security
    isempty(security) && return default_auth
    for requirement in security
        # an empty security requirement documents optional authentication
        isempty(requirement) && return default_auth
    end
    requirement = first(security)
    length(requirement) == 1 || throw(ArgumentError(string(
        "operation ",
        entry.operation.id,
        " requires multiple simultaneous security schemes; Servo endpoints",
        " declare a single AuthScheme, so pass a composed scheme through `auth`",
    )))
    scheme_name = first(first(requirement))
    haskey(auth, scheme_name) || throw(ArgumentError(string(
        "operation ",
        entry.operation.id,
        " requires security scheme ",
        repr(scheme_name),
        "; pass auth = Dict(",
        repr(scheme_name),
        " => <Servo.AuthScheme>)",
    )))
    return auth[scheme_name]
end

function _servo_handler(impl, entry, names)
    return function (request)
        captures = Servo.pathparams()
        path_params = Dict{String,String}()
        for (route_symbol, wire) in names
            haskey(captures, route_symbol) &&
                (path_params[wire] = captures[route_symbol])
        end
        headers = request.headers
        content_values = _header_values(headers, "Content-Type")
        content_type = isempty(content_values) ? "" : first(content_values)
        bytes = Vector{UInt8}(codeunits(String(request.body)))
        local args, kwargs
        try
            parts = _servo_multipart_parts(content_type, bytes)
            args, kwargs = _operation_arguments(
                entry,
                path_params,
                _servo_query(request),
                headers,
                bytes,
                parts,
            )
        catch error
            status, response_headers, payload = _request_error_response(error)
            return Servo.Response(status, payload; headers = response_headers)
        end
        result = getfield(impl, entry.invoke)(request, args...; kwargs...)
        result isa Servo.Response && return result
        status, response_headers, payload = try
            _server_response(entry.operation, result)
        catch error
            _response_error_payload(error)
        end
        return Servo.Response(status, payload; headers = response_headers)
    end
end

# register!(router::Servo.Router, impl; path_prefix = "", auth = Dict(),
#           default_auth = Servo.Public(), middleware = nothing) -> router
#
# Mount every documented operation on `router`, dispatching to the handler
# functions `impl` defines (one per operation; the expected signatures are
# listed at the top of this file). Handlers may return a documented typed
# value (encoded and validated automatically), `nothing` (a 204 response), or
# a full `Servo.Response` for anything custom. Operations that declare
# security requirements resolve their scheme name through `auth`
# (scheme name => Servo.AuthScheme); operations without security use
# `default_auth`. `middleware` wraps each operation handler:
# `middleware(handler) -> handler`. `register` is an alias kept for
# familiarity with OpenAPI.jl 0.2.x generated servers.
function register!(
    router::Servo.Router,
    impl;
    path_prefix::AbstractString = "",
    auth::AbstractDict = Dict{String,Servo.AuthScheme}(),
    default_auth::Servo.AuthScheme = Servo.Public(),
    middleware = nothing,
)
    missing_ops = _missing_implementations(impl)
    isempty(missing_ops) || throw(ArgumentError(string(
        "implementation is missing handler functions:\n    ",
        join(missing_ops, "\n    "),
    )))
    for entry in _SERVER_OPS
        route, names = _servo_route(entry)
        handler = _servo_handler(impl, entry, names)
        middleware === nothing || (handler = middleware(handler))
        Servo.register!(
            router,
            Symbol(entry.method),
            string(path_prefix, route),
            handler;
            auth = _servo_auth(entry, auth, default_auth),
            name = entry.operation.id,
        )
    end
    return router
end
const register = register!
"""

function OpenAPI.server_source(::Val{:Servo}, plan::OpenAPI.ServerPlan)
    unsupported = String[
        string(operation.operation.method, ' ', operation.operation.path) for
        operation in plan.operations if
        !(Symbol(uppercase(String(operation.operation.method))) in Servo.METHODS)
    ]
    isempty(unsupported) || throw(ArgumentError(string(
        "Servo routers do not support these operations' methods: ",
        join(unsupported, ", "),
    )))
    return OpenAPI.server_module_source(
        plan;
        imports = GENERATED_SERVO_SERVER_IMPORTS,
        glue = GENERATED_SERVO_SERVER_GLUE,
    )
end

end # module
