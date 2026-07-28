# The HTTP transport is a package extension (ServoHTTPExt, triggered by loading
# HTTP.jl) so that core Servo stays free of the HTTP dependency tree — notably
# for juliac/trim compilation of the core machinery. These empty generic
# functions are the seam the extension fills in.

"""
    Servo.serve!(router=Servo.ROUTER; host="0.0.0.0", port=8080, cors=false, accesslog=false, kw...)

Start (non-blocking) an HTTP server for a router and return the server handle
(`wait` it to block, `close` it to stop). Prefer [`Servo.run!`](@ref), which also
loads config and applies profile conventions; `serve!` is the bare transport
entrypoint. Requires the HTTP package to be loaded (`using HTTP`); remaining `kw`
pass through to `HTTP.serve!`.
"""
function serve! end

"""the local port a server (returned by `serve!`/`run!`) is bound to"""
function port end

httpavailable() = Base.get_extension(@__MODULE__, :ServoHTTPExt) !== nothing

function checkhttp()
    httpavailable() || throw(ArgumentError(
        "serving requires the HTTP package: add HTTP to your project and load it (`using HTTP`)"))
    return
end
