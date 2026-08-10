"""
    Servo.HTTPError(status, message="")

Exception any layer (handler, auth scheme, binding) can throw to produce a response
with the given status code. The message is serialized into the standard error
envelope `(; error = (; message, code))` using the endpoint's `Format`.
"""
struct HTTPError <: Exception
    status::Int
    message::String
end
HTTPError(status::Integer) = HTTPError(status, "")

Base.showerror(io::IO, e::HTTPError) = print(io, "HTTPError(", e.status, "): ", e.message)

# Convert exceptions with request-level meaning into Servo's explicit HTTP
# error type. Endpoint code can override this default by catching an exception
# and throwing its own HTTPError before the exception reaches the transport.
function _httperror(error)::Union{HTTPError, Nothing}
    error isa HTTPError && return error
    error isa ArgumentError && return HTTPError(400, error.msg)
    return nothing
end

badrequest(msg::AbstractString="bad request") = throw(HTTPError(400, String(msg)))
unauthorized(msg::AbstractString="unauthorized") = throw(HTTPError(401, String(msg)))
forbidden(msg::AbstractString="forbidden") = throw(HTTPError(403, String(msg)))
notfound(msg::AbstractString="not found") = throw(HTTPError(404, String(msg)))
