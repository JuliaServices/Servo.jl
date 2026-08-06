# Servo.jl

*An application driver for Julia: turn a package of useful functions into a
running service.*

```julia
module MyApp
using Servo, JSON

struct Order
    item::String
    qty::Int
end

Servo.@init begin
    # every endpoint declares its auth explicitly — `public` or an AuthScheme
    Servo.@GET "/v1/orders/{id}" public function getorder(id::Int; expand::Bool=false)
        return (; id, expand)                    # serialized as JSON
    end

    Servo.@POST "/v1/orders" public function neworder(order::Order)
        return Servo.Response(201, JSON.json((; created = order.item)))
    end
end

run(profile=""; kw...) = Servo.run("MyApp", profile; kw...)

end
```

```julia
julia> MyApp.run()   # loads config for the profile, serves HTTP, CORS when local
```

Path segments bind positional arguments, the request body binds the trailing
positional argument, query parameters bind keyword arguments — all coerced to
the declared types, with 400s (not stringly-typed surprises) on bad input.

Servo also supplies a reusable bearer authentication scheme:

```julia
function validator(token, request)
    return token == "secret" ? "user-1" : nothing
end

Servo.@GET "/v1/private" Servo.BearerAuth(validator) function private_resource()
    return (; user=Servo.principal())
end
```

The validator can verify a JWT, query a token store, and return a rich
application context. See [DESIGN.md](DESIGN.md#auth) for the complete auth
interface.

## OpenAPI integration

Add OpenAPI.jl to the application and load it with Servo. Servo owns the
optional integration (the `ServoOpenAPIExt` package extension), so OpenAPI.jl
does not depend on Servo. It works in both directions.

Describe the running app's routes as an OpenAPI document:

```julia
using Servo, JSON, OpenAPI

OpenAPI.register!(Servo.ROUTER; title = "My service", version = "1.0.0")
```

This registers `/openapi.json`. Use `OpenAPI.document(Servo.ROUTER; ...)` to
build the same document without adding a route. The integration describes typed
path, query, and body parameters and infers response schemas for typed endpoint
binders; raw handlers keep an unknown response schema because Servo cannot
infer their response contract safely.

Or treat an OpenAPI document as the source of truth and generate a
`Servo.Router`-based server-stub module from it:

```julia
using Servo, OpenAPI

OpenAPI.server("openapi.yaml"; framework = :Servo, path = "MyServer.jl")
include("MyServer.jl")

router = Servo.Router()
MyServer.register!(router, HandlersModule;
                   auth = Dict("bearerAuth" => Servo.BearerAuth(validate_token)))
Servo.serve!(router)
```

The generated module header lists the handler functions to implement (one per
documented operation, with typed decoded parameters and bodies). Operations
that declare OpenAPI security requirements resolve their scheme names through
the `auth` mapping; operations without security default to `Servo.Public()`.

See [DESIGN.md](DESIGN.md) for the full design: the `Format` and transport
seams, the auth contract, config layering, and what's deliberately deferred.
