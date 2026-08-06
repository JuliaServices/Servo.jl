"""
    Servo.Format

Abstract supertype for wire (de)serialization formats. A `Format` says how request
bodies become function arguments and how return values become response bodies —
independent of the transport that carried them.

Interface (implement for a concrete `Format` subtype `F`):

- `Servo.serialize(f::F, value) -> AbstractString | AbstractVector{UInt8}`
- `Servo.deserialize(f::F, ::Type{T}, body) -> T` where `body` is
  `AbstractString | AbstractVector{UInt8}`
- `Servo.mime(f::F) -> String` (content-type advertised by responses)
"""
abstract type Format end

function serialize end
function deserialize end

mime(::Format) = "application/octet-stream"

_tostring(x::AbstractString) = String(x)
_tostring(x) = String(copy(x))

"""
    JSONFormat()

Marker for JSON (de)serialization, the default format for endpoints. The
implementation lives in the `ServoJSONExt` package extension, which loads
automatically when JSON.jl is loaded alongside Servo — add `JSON` to your app's
dependencies and `using JSON`.
"""
struct JSONFormat <: Format end
mime(::JSONFormat) = "application/json; charset=utf-8"

"""
    TextFormat()

Plain-text format: response bodies are `string(value)`; request bodies can only
bind to `String` (or `Any`) parameters. Has no dependencies; also serves as the
reference `Format` implementation.
"""
struct TextFormat <: Format end
mime(::TextFormat) = "text/plain; charset=utf-8"
serialize(::TextFormat, x) = string(x)
deserialize(::TextFormat, ::Type{Any}, body) = _tostring(body)
deserialize(::TextFormat, ::Type{T}, body) where {T<:AbstractString} = convert(T, _tostring(body))

"""
    Servo.errorbody(fmt::Format, message, code) -> AbstractString | AbstractVector{UInt8}

The response body for a request-level error in this format. `JSONFormat` wraps
the message in the stable `(; error = (; message, code))` envelope; `TextFormat`
returns the bare message, since a plain-text client cannot parse a printed
named tuple (and Base's generic tuple `show` machinery is dynamically
dispatched — unresolvable under juliac --trim).

Deliberately no `::Format` fallback method: `errorresponse` calls this on an
abstract `Endpoint.format` slot, and that call only union-splits into guarded
static calls when every applicable method has a concrete format type. A format
without a method falls back to the bare message via `errorresponse`'s catch.
"""
errorbody(fmt::JSONFormat, message::String, code::Int) =
    serialize(fmt, (; error = (; message, code)))
errorbody(::TextFormat, message::String, code::Int) = message

# JSONFormat requires the JSON.jl-backed extension; error at endpoint construction
# time with a fix, rather than a MethodError on the first request.
function checkformat(f::Format)
    if f isa JSONFormat && Base.get_extension(@__MODULE__, :ServoJSONExt) === nothing
        throw(ArgumentError("JSONFormat requires the JSON package: add JSON to your project and load it (`using JSON`) before defining endpoints"))
    end
    return f
end
