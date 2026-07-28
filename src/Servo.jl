module Servo

using Logging, Sockets
import Figgy

# core interface (no external dependencies in design: these files only use Base)
include("errors.jl")
include("formats.jl")
include("auth.jl")
include("endpoints.jl")
include("router.jl")
include("binding.jl")
include("ratelimit.jl")
include("macros.jl")

# concrete machinery; the HTTP transport itself lives in the ServoHTTPExt
# package extension (loaded when HTTP.jl is), keeping core trim-compilable
include("config.jl") # Figgy
include("serve.jl")  # serve!/port stubs the HTTP extension implements
include("run.jl")

end # module
