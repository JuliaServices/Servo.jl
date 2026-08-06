using Test, Servo, HTTP, JSON, OpenAPI

# Endpoints are declared at the top level so the generated binders stay
# statically inferable (OpenAPI response schemas come from binder return types).
struct DocWidget
    id::Int
    name::String
end

const DOC_ROUTER = Servo.Router()

Servo.@GET DOC_ROUTER "/widgets/{id}" public function openapi_getwidget(id::Int; verbose::Bool = false)::DocWidget
    return DocWidget(id, verbose ? "verbose" : "plain")
end

Servo.@POST DOC_ROUTER "/widgets" public format=Servo.JSONFormat() function openapi_addwidget(w::DocWidget)::DocWidget
    return w
end

@testset "OpenAPI document generation from a Servo router" begin
    operations = OpenAPI.operations(DOC_ROUTER)
    @test length(operations) == 2
    @test Set(op.id for op in operations) ==
          Set(["openapi_getwidget", "openapi_addwidget"])

    document = OpenAPI.document(DOC_ROUTER; title = "Doc", version = "1.2.3")
    @test document["info"]["title"] == "Doc"
    @test haskey(document["paths"], "/widgets/{id}")
    getop = document["paths"]["/widgets/{id}"]["get"]
    @test getop["operationId"] == "openapi_getwidget"
    names = [(p["name"], p["in"]) for p in getop["parameters"]]
    @test ("id", "path") in names
    @test ("verbose", "query") in names
    @test haskey(document["components"]["schemas"], "DocWidget")

    OpenAPI.register!(DOC_ROUTER; title = "Doc", version = "1.2.3")
    server = Servo.serve!(DOC_ROUTER; host = "127.0.0.1", port = 0)
    try
        port = Servo.port(server)
        response = HTTP.get(
            "http://127.0.0.1:$port/openapi.json";
            status_exception = false,
        )
        @test response.status == 200
        served = JSON.parse(String(response.body))
        @test haskey(served["paths"], "/widgets/{id}")
        # the discovery endpoint documents the live route table but not itself
        @test !haskey(served["paths"], "/openapi.json")
    finally
        close(server)
    end
end

const SERVO_GEN_DOCUMENT = OpenAPI.obj(
    "openapi" => "3.1.0",
    "info" => OpenAPI.obj("title" => "Servo Gen", "version" => "1.0.0"),
    "paths" => OpenAPI.obj(
        "/things/{thing-id}" => OpenAPI.obj(
            "get" => OpenAPI.obj(
                "operationId" => "getThing",
                "security" => Any[OpenAPI.obj("bearer" => Any[])],
                "parameters" => Any[
                    OpenAPI.obj(
                        "name" => "thing-id",
                        "in" => "path",
                        "required" => true,
                        "schema" => OpenAPI.obj("type" => "integer"),
                    ),
                ],
                "responses" => OpenAPI.obj(
                    "200" => OpenAPI.obj(
                        "description" => "ok",
                        "content" => OpenAPI.obj(
                            "application/json" => OpenAPI.obj(
                                "schema" => OpenAPI.obj(
                                    "type" => "object",
                                    "properties" => OpenAPI.obj(
                                        "id" => OpenAPI.obj("type" => "integer"),
                                        "owner" => OpenAPI.obj("type" => "string"),
                                    ),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        ),
        "/things" => OpenAPI.obj(
            "post" => OpenAPI.obj(
                "operationId" => "addThing",
                "requestBody" => OpenAPI.obj(
                    "required" => true,
                    "content" => OpenAPI.obj(
                        "application/json" => OpenAPI.obj(
                            "schema" => OpenAPI.obj(
                                "type" => "object",
                                "required" => Any["label"],
                                "properties" => OpenAPI.obj(
                                    "label" => OpenAPI.obj("type" => "string"),
                                ),
                            ),
                        ),
                    ),
                ),
                "responses" => OpenAPI.obj(
                    "201" => OpenAPI.obj(
                        "description" => "created",
                        "content" => OpenAPI.obj(
                            "application/json" => OpenAPI.obj(
                                "schema" => OpenAPI.obj(
                                    "type" => "object",
                                    "properties" => OpenAPI.obj(
                                        "label" => OpenAPI.obj("type" => "string"),
                                    ),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    ),
    "components" => OpenAPI.obj(
        "securitySchemes" => OpenAPI.obj(
            "bearer" => OpenAPI.obj("type" => "http", "scheme" => "bearer"),
        ),
    ),
)

@testset "OpenAPI server generation for Servo" begin
    source = OpenAPI.server(SERVO_GEN_DOCUMENT; framework = :Servo, name = "ServoGenServer")
    @test source == OpenAPI.server(SERVO_GEN_DOCUMENT; framework = :Servo, name = "ServoGenServer")
    @test occursin("Servo.register!", source)

    host = Module(:ServoGenHost)
    Base.include_string(host, source, "ServoGenServer.jl")
    S = Base.invokelatest(getfield, host, :ServoGenServer)
    sregister(args...; kwargs...) =
        Base.invokelatest(getfield(S, :register!), args...; kwargs...)

    impl = Module(:ServoGenImpl)
    Base.include_string(
        impl,
        """
        getthing(req, thing_id) = (; id = thing_id, owner = "user-1")
        addthing(req, body) = (; label = body.label)
        """,
        "ServoGenImpl.jl",
    )

    @testset "security schemes resolve through the auth mapping" begin
        error = try
            sregister(Servo.Router(), impl)
            nothing
        catch caught
            caught
        end
        @test error isa ArgumentError
        @test occursin("bearer", error.msg)
    end

    router = Servo.Router()
    auth = Dict(
        "bearer" => Servo.BearerAuth(
            (token, request) -> token == "secret" ? "user-1" : nothing,
        ),
    )
    sregister(router, impl; auth)

    server = Servo.serve!(router; host = "127.0.0.1", port = 0)
    try
        port = Servo.port(server)
        base = "http://127.0.0.1:$port"

        unauthorized = HTTP.get("$base/things/5"; status_exception = false)
        @test unauthorized.status == 401

        authorized = HTTP.get(
            "$base/things/5";
            headers = ["Authorization" => "Bearer secret"],
            status_exception = false,
        )
        @test authorized.status == 200
        thing = JSON.parse(String(authorized.body))
        @test thing["id"] == 5
        @test thing["owner"] == "user-1"

        invalid = HTTP.get(
            "$base/things/nope";
            headers = ["Authorization" => "Bearer secret"],
            status_exception = false,
        )
        @test invalid.status == 400
        @test occursin("thing-id", String(invalid.body))

        created = HTTP.post(
            "$base/things";
            headers = ["Content-Type" => "application/json"],
            body = JSON.json((; label = "new thing")),
            status_exception = false,
        )
        @test created.status == 201
        @test JSON.parse(String(created.body))["label"] == "new thing"
    finally
        close(server)
    end

    @testset "methods without Servo equivalents fail at emission" begin
        document = OpenAPI.obj(
            "openapi" => "3.1.0",
            "info" => OpenAPI.obj("title" => "Opts", "version" => "1.0.0"),
            "paths" => OpenAPI.obj(
                "/cors" => OpenAPI.obj(
                    "options" => OpenAPI.obj(
                        "operationId" => "corsOptions",
                        "responses" => OpenAPI.obj(
                            "204" => OpenAPI.obj("description" => "empty"),
                        ),
                    ),
                ),
            ),
        )
        error = try
            OpenAPI.server(document; framework = :Servo)
            nothing
        catch caught
            caught
        end
        @test error isa ArgumentError
        @test occursin("OPTIONS", error.msg)
    end
end
