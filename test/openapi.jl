using OpenAPI, Dates

struct OpenAPIWidget
    id::Int
    tags::Vector{String}
end

const OPENAPI_ROUTER = Servo.Router()

Servo.@GET OPENAPI_ROUTER "/api/widgets/{id}" public function openapi_getwidget(
    id::Int;
    tags::Vector{String} = String[],
)
    return OpenAPIWidget(id, tags)
end

Servo.@DELETE OPENAPI_ROUTER "/api/widgets/{id}" public function openapi_rmwidget(id::Int)
    return nothing
end

Servo.@GET OPENAPI_ROUTER "/api/docs/{page...}" public function openapi_docpage(page::String)
    return (; page)
end

Servo.register!(
    OPENAPI_ROUTER,
    :GET,
    "/api/ping/{name}",
    request -> "pong:$(Servo.pathparams()[:name])";
    auth = Servo.Public(),
    name = "openapi_ping",
)

Servo.register!(
    OPENAPI_ROUTER,
    :GET,
    "/api/static/**",
    request -> Servo.Response(200, "blob");
    auth = Servo.Public(),
    name = "openapi_static",
)

OpenAPI.register!(
    OPENAPI_ROUTER;
    title = "Servo integration",
    version = "1.0.0",
)

@testset "Servo OpenAPI extension" begin
    operations = OpenAPI.operations(OPENAPI_ROUTER)
    by_id = Dict(operation.id => operation for operation in operations)

    @test Set(keys(by_id)) == Set([
        "openapi_getwidget",
        "openapi_rmwidget",
        "openapi_docpage",
        "openapi_ping",
    ])
    @test by_id["openapi_getwidget"].responsetype == OpenAPIWidget
    @test by_id["openapi_getwidget"].params[1].location == :path
    @test by_id["openapi_rmwidget"].responsetype === Nothing
    @test by_id["openapi_docpage"].path == "/api/docs/{page}"
    @test by_id["openapi_ping"].responsetype === nothing
    @test !haskey(by_id, "openapi_static")

    document = OpenAPI.document(
        OPENAPI_ROUTER;
        title = "Servo integration",
        version = "1.0.0",
    )
    response = document["paths"]["/api/widgets/{id}"]["get"]["responses"]["200"]
    @test response["content"]["application/json"]["schema"]["\$ref"] ==
          "#/components/schemas/OpenAPIWidget"
    @test haskey(
        document["paths"]["/api/widgets/{id}"]["delete"]["responses"],
        "204",
    )
    @test OpenAPI.validate(document) === document

    server = Servo.serve!(OPENAPI_ROUTER; host = "127.0.0.1", port = 0)
    try
        base = "http://127.0.0.1:$(Servo.port(server))"
        discovered = OpenAPI.read(base * "/openapi.json")
        @test discovered["info"]["title"] == "Servo integration"
        @test !haskey(discovered["paths"], "/openapi.json")

        source = OpenAPI.client(discovered; name = "ServoExtensionClient")
        host = Module(:ServoExtensionClientHost)
        Base.include_string(host, source, "ServoExtensionClient.jl")
        client_module = Base.invokelatest(getfield, host, :ServoExtensionClient)
        binding(name) = Base.invokelatest(getfield, client_module, name)
        call(name, args...; kwargs...) =
            Base.invokelatest(binding(name), args...; kwargs...)

        call(:server!, base)
        widget = call(:openapi_getwidget, 7; tags = ["a", "b"])
        @test widget isa binding(:OpenAPIWidget)
        @test widget.id == 7
        @test widget.tags == ["a", "b"]
        @test call(:openapi_rmwidget, 7) === nothing
        @test call(:openapi_docpage, "intro").page == "intro"
    finally
        close(server)
    end
end
