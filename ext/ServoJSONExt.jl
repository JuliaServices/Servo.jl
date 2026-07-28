# Implements Servo's Format interface for JSONFormat using JSON.jl.
# Loads automatically when both Servo and JSON are loaded.
module ServoJSONExt

using Servo, JSON

Servo.serialize(::Servo.JSONFormat, x) = JSON.json(x)
Servo.deserialize(::Servo.JSONFormat, ::Type{Any}, body) = JSON.parse(body)
Servo.deserialize(::Servo.JSONFormat, ::Type{T}, body) where {T} = JSON.parse(body, T)

end # module
