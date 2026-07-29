# @GET/@POST/@PUT/@DELETE/@PATCH: define a function and register it as an endpoint,
# deriving the argument binding from the function's own signature.

struct ParamSpec
    name::Symbol
    type::Any      # type *expression*, evaluated in the caller's module
    source::Symbol
    required::Bool
    default::Any   # default *expression* for optional query params
end
ParamSpec(name, type, source, required) = ParamSpec(name, type, source, required, nothing)

function parsesignature(funcdef, placeholders::Vector{Symbol})
    sig = nothing
    if funcdef isa Expr && funcdef.head == :function
        sig = funcdef.args[1]
    elseif funcdef isa Expr && funcdef.head == :(=)
        sig = funcdef.args[1]
    end
    # unwrap return-type annotations and where clauses
    while sig isa Expr && sig.head in (:(::), :where)
        sig = sig.args[1]
    end
    sig isa Expr && sig.head == :call || throw(ArgumentError(
        "expected a named function definition, e.g. `function simulate(...) ... end`"))
    fname = sig.args[1]
    fname isa Symbol || throw(ArgumentError(
        "endpoint functions must have a simple name; got `$fname`"))
    argexprs = sig.args[2:end]
    kwexprs = []
    if !isempty(argexprs) && argexprs[1] isa Expr && argexprs[1].head == :parameters
        kwexprs = argexprs[1].args
        argexprs = argexprs[2:end]
    end
    specs = ParamSpec[]
    for a in argexprs
        push!(specs, positionalspec(a, placeholders))
    end
    for a in kwexprs
        push!(specs, keywordspec(a))
    end
    return fname, specs
end

argname(a) = a isa Symbol ? a :
    a isa Expr && a.head == :(::) && length(a.args) == 2 && a.args[1] isa Symbol ? a.args[1] :
    nothing
argtype(a) = a isa Symbol ? :Any : a.args[2]

function positionalspec(a, placeholders::Vector{Symbol})
    a isa Expr && a.head == :kw && throw(ArgumentError(
        "positional argument `$(a.args[1])` has a default value; query parameters " *
        "must be keyword arguments (after `;`)"))
    name = argname(a)
    name === nothing && throw(ArgumentError(
        "unsupported endpoint argument `$a`: expected `name` or `name::Type`"))
    return ParamSpec(name, argtype(a), name in placeholders ? :path : :body, true)
end

function keywordspec(a)
    if a isa Expr && a.head == :kw
        name = argname(a.args[1])
        name === nothing && throw(ArgumentError(
            "unsupported endpoint keyword argument `$(a.args[1])`"))
        return ParamSpec(name, argtype(a.args[1]), :query, false, a.args[2])
    end
    name = argname(a)
    name === nothing && throw(ArgumentError(
        "unsupported endpoint keyword argument `$a`: expected `name`, `name::Type`, " *
        "or `name=default` (splats are not supported)"))
    return ParamSpec(name, argtype(a), :query, true)
end

function endpointexpr(method::Symbol, args...)
    usage = "usage: Servo.@$method [router] \"/path\" <auth> [format=...] <function definition>"
    length(args) >= 2 || throw(ArgumentError(usage))
    i = 1
    router = :(Servo.ROUTER)
    if !(args[i] isa AbstractString)
        router = args[i]
        i += 1
        i <= length(args) - 1 || throw(ArgumentError(usage))
    end
    args[i] isa AbstractString || throw(ArgumentError(
        "the endpoint path must be a string literal; $usage"))
    path = String(args[i])
    funcdef = args[end]
    authex = nothing
    formatex = :(Servo.JSONFormat())
    for a in args[i+1:end-1]
        if a === :public
            authex = :(Servo.Public())
        elseif a isa Expr && a.head == :(=) && a.args[1] === :format
            formatex = esc(a.args[2])
        elseif a isa Expr && a.head == :(=) && a.args[1] === :auth
            authex = esc(a.args[2])
        elseif authex === nothing
            authex = esc(a)
        else
            throw(ArgumentError("unrecognized @$method argument `$a`; $usage"))
        end
    end
    authex === nothing && throw(ArgumentError(
        "@$method \"$path\" does not declare an auth scheme: every endpoint must either be " *
        "explicitly `public` or provide a `Servo.AuthScheme`, e.g. " *
        "`Servo.@$method \"$path\" public function ... end`"))
    placeholders = Symbol[s for s in parsepattern(path) if s isa Symbol]
    fname, specs = parsesignature(funcdef, placeholders)
    paramexprs = [:(Servo.Param($(QuoteNode(s.name)), $(esc(s.type)), $(QuoteNode(s.source)), $(s.required)))
                  for s in specs]
    # `target` is a single-assignment `let` binding: closures capturing it stay
    # unboxed (capturing the named function binding directly would box it, since
    # method definitions are potentially-repeated assignments)
    return quote
        $(esc(funcdef))
        Servo.register!($(esc(router)), let target = $(esc(fname))
            Servo.Endpoint(
                name = $(String(fname)),
                method = $(QuoteNode(method)),
                path = $path,
                target = target,
                params = Servo.Param[$(paramexprs...)],
                binder = Servo.Binder($(binderexpr(specs))),
                auth = $authex,
                format = $formatex,
            )
        end)
    end
end

# Generate the statically-typed binder for an endpoint function: parameter types
# appear as literal `Type` arguments so every extraction/coercion call — and the
# final invocation of the target — dispatches statically (juliac/trim friendly).
# Arguments bind to locals named like the function's own arguments, in signature
# order, so later keyword defaults may reference earlier arguments as usual.
function binderexpr(specs::Vector{ParamSpec})
    stmts = Any[]
    for s in specs
        val = if s.source == :path
            :(Servo.pathvalue($(esc(s.type)), pathparams, $(QuoteNode(s.name))))
        elseif s.source == :body
            :(Servo.bodyvalue(fmt, $(esc(s.type)), body, $(QuoteNode(s.name))))
        elseif s.required
            :(Servo.queryvalue($(esc(s.type)), query, $(QuoteNode(s.name))))
        else
            :(Servo.hasquery(query, $(String(s.name))) ?
                Servo.queryvalue($(esc(s.type)), query, $(QuoteNode(s.name))) : $(esc(s.default)))
        end
        push!(stmts, :($(esc(s.name)) = $val))
    end
    posargs = [esc(s.name) for s in specs if s.source in (:path, :body)]
    kwargs = [Expr(:kw, s.name, esc(s.name)) for s in specs if s.source == :query]
    call = isempty(kwargs) ? Expr(:call, :target, posargs...) :
        Expr(:call, :target, Expr(:parameters, kwargs...), posargs...)
    return :(function (fmt, pathparams, query, body)
        $(stmts...)
        return $call
    end)
end

"""
    Servo.@GET [router] "/path" <auth> [format=...] <function definition>

(and `@POST`, `@PUT`, `@DELETE`, `@PATCH`)

Define a function and register it as an endpoint in one step. The binding of
transport data to arguments is derived from the path and the function signature:

- a positional argument whose name matches a `{segment}` in the path binds that
  path parameter, coerced to the argument's declared type;
- the final positional argument *not* matching a path parameter binds the request
  body, deserialized with the endpoint's format (`POST`/`PUT`/`PATCH` only);
- keyword arguments bind query parameters (coerced to their declared types);
  keywords without defaults are required and produce a 400 when absent.

The auth declaration is mandatory: the literal `public` (== `Servo.Public()`, no
authentication, default rate limiting under `run!`) or any `Servo.AuthScheme`
value. Omitting it is an error at macro-expansion time.

```julia
Servo.@GET "/v1/users/{id}" TokenAuth() function getuser(id::Int; expand::Bool=false)
    ...
end

Servo.@POST "/v1/simulate" public function simulate(spec::SimulationSpec; days::Int=365)
    ...
end
```
"""
macro GET(args...)
    endpointexpr(:GET, args...)
end

for M in (:POST, :PUT, :DELETE, :PATCH, :QUERY)
    @eval macro $M(args...)
        endpointexpr($(QuoteNode(M)), args...)
    end
end
