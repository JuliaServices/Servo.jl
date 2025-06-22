macro GET(router, path, handler)
    fargs = parseargs(path, handler)
    esc(quote
        @info "registering GET route: $($path)"
        Servo.HTTP.register!($router, "GET", $path, Servo.json_middleware($handler, Servo.Arg[$(fargs...)]))
        #TODO: how do we avoid over-writing OPTIONS paths too much?
        # maybe this needs to be builtin to HTTP.Router more tightly?
        Servo.HTTP.register!($router, "OPTIONS", $path, req -> Servo.HTTP.Response(200))
    end)
end

macro GET(path, handler)
    esc(:(Servo.@GET(Servo.ROUTER, $path, $handler)))
end

macro POST(router, path, handler)
    fargs = parseargs(path, handler)
    esc(quote
        @info "registering POST route: $($path)"
        Servo.HTTP.register!($router, "POST", $path, Servo.json_middleware($handler, Servo.Arg[$(fargs...)]))
        Servo.HTTP.register!($router, "OPTIONS", $path, req -> Servo.HTTP.Response(200))
    end)
end

macro POST(path, handler)
    esc(:(Servo.@POST(Servo.ROUTER, $path, $handler)))
end

macro PUT(router, path, handler)
    fargs = parseargs(path, handler)
    esc(quote
        @info "registering PUT route: $($path)"
        Servo.HTTP.register!($router, "PUT", $path, Servo.json_middleware($handler, Servo.Arg[$(fargs...)]))
        Servo.HTTP.register!($router, "OPTIONS", $path, req -> Servo.HTTP.Response(200))
    end)
end

macro PUT(path, handler)
    esc(:(Servo.@PUT(Servo.ROUTER, $path, $handler)))
end

macro DELETE(router, path, handler)
    fargs = parseargs(path, handler)
    esc(quote
        @info "registering DELETE route: $($path)"
        Servo.HTTP.register!($router, "DELETE", $path, Servo.json_middleware($handler, Servo.Arg[$(fargs...)]))
        Servo.HTTP.register!($router, "OPTIONS", $path, req -> Servo.HTTP.Response(200))
    end)
end

macro DELETE(path, handler)
    esc(:(Servo.@DELETE(Servo.ROUTER, $path, $handler)))
end
