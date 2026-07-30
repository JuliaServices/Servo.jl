module Servo

using Logging
using Base.ScopedValues
import Figgy, HTTP

# core interface: these files only use Base
include("errors.jl")
include("formats.jl")
include("auth.jl")
include("handlerfn.jl")
include("endpoints.jl")
include("router.jl")
include("binding.jl")
include("ratelimit.jl")
include("macros.jl")

# concrete machinery
include("config.jl") # Figgy
include("http.jl")   # HTTP transport
include("run.jl")

end # module
