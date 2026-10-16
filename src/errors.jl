"""
    Servo.HTTPError(status, message=""; headers=[], body=nothing)

Exception any layer (handler, auth scheme, binding) can throw to produce a response
with the given status code. The message is serialized into the standard error
envelope `(; error = (; message, code))` using the endpoint's `Format`.

`headers` are added to the error response, e.g. `WWW-Authenticate` on a 401 or
`Retry-After` on a 429. A `body` string replaces the envelope verbatim, for
clients that expect another error shape. It is sent with the endpoint format's
`Content-Type` unless `headers` sets one.
"""
struct HTTPError <: Exception
    status::Int
    message::String
    headers::Vector{Pair{String, String}}
    body::Union{Nothing, String}
end
HTTPError(status::Integer, message::AbstractString=""; headers::AbstractVector=Pair{String, String}[],
          body::Union{Nothing, AbstractString}=nothing) =
    HTTPError(Int(status), String(message), convert(Vector{Pair{String, String}}, headers),
              body === nothing ? nothing : String(body))

Base.showerror(io::IO, e::HTTPError) = print(io, "HTTPError(", e.status, "): ", e.message)

badrequest(msg::AbstractString="bad request") = throw(HTTPError(400, String(msg)))
unauthorized(msg::AbstractString="unauthorized") = throw(HTTPError(401, String(msg)))
forbidden(msg::AbstractString="forbidden") = throw(HTTPError(403, String(msg)))
notfound(msg::AbstractString="not found") = throw(HTTPError(404, String(msg)))
