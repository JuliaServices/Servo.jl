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

## OpenAPI integration

Add OpenAPI.jl to the application and load it with Servo. Servo owns the
optional integration, so OpenAPI.jl does not depend on Servo.

```julia
using Servo, JSON, OpenAPI

OpenAPI.register!(
    Servo.ROUTER;
    title = "My service",
    version = "1.0.0",
)
```

This registers `/openapi.json`. Use `OpenAPI.document(Servo.ROUTER; ...)` to
build the same document without adding a route. The integration describes typed
path, query, and body parameters. It infers response schemas for typed endpoint
binders. Raw handlers keep an unknown response schema because Servo cannot infer
their response contract safely.

See [DESIGN.md](DESIGN.md) for the full design: the `Format` and transport
seams, the auth contract, config layering, and what's deliberately deferred.
