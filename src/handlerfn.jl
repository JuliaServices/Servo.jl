# Type-erased, statically-dispatched request handlers — the "cfunction trick"
# (borrowed from Reseau's task scheduler): a singleton wrapper callable plus a
# @generated per-handler-type @cfunction whose first C argument carries the
# handler object (Ref{H}), so no runtime closure trampolines are needed. The
# request data and result cross the boundary through a concrete mutable
# HandlerCall passed as a raw pointer (the trim verifier resolves cfunctions
# whose C signatures are Ref/pointer/primitive shaped, not boxed `Any`s).
#
# The result: `Endpoint` needs no type parameters (a `Vector{Endpoint}` is fully
# concrete, and `handle` on a router-matched endpoint has zero dynamic
# dispatch), while everything *inside* each handler still compiles against the
# handler's concrete types — the property juliac --trim=safe verification needs.

# one request crossing the erased boundary: every field concrete (`body` empty
# means "no body"; `clientip` empty means "unknown") so the handler call needs
# no union-splitting, which the trim verifier cannot resolve
mutable struct HandlerCall
    pathparams::Dict{Symbol, String}
    query::Dict{String, String}
    body::Vector{UInt8}
    clientip::String
    req::Any
    result::Any
end

struct _HandlerCallWrapper <: Function end

function (::_HandlerCallWrapper)(h::H, callptr::Ptr{Cvoid}) where {H}
    call = unsafe_pointer_to_objref(callptr)::HandlerCall
    call.result = h(call)
    return nothing
end

@generated function _handler_fptr(::Type{H}) where {H}
    quote
        @cfunction($(_HandlerCallWrapper()), Cvoid, (Ref{$H}, Ptr{Cvoid}))
    end
end

"""
    HandlerFn(handler)

Type-erased request handler: calling one goes through a fixed-signature `ccall`
to a per-handler-type `@cfunction`, so the call site is statically resolvable
even though `HandlerFn` itself carries no type parameter.

The function pointer is captured at construction, which is why endpoints must be
constructed **at runtime** — registration belongs in your app's `__init__` (see
`Servo.@init`), never at package precompile time, where the stored pointer would
go stale.
"""
struct HandlerFn
    ptr::Ptr{Cvoid}    # @cfunction pointer, specialized on the handler's type
    objptr::Ptr{Cvoid} # pointer to the handler object
    root::Any          # GC root for the handler; never dispatched on
end

function HandlerFn(h::H) where {H}
    ptr = _handler_fptr(H)
    objref = Base.cconvert(Ref{H}, h)
    objptr = Ptr{Cvoid}(Base.unsafe_convert(Ref{H}, objref))
    return HandlerFn(ptr, objptr, objref)
end

function (f::HandlerFn)(pathparams::Dict{Symbol, String}, query::Dict{String, String},
                        body::Vector{UInt8}, clientip::String, req)
    call = HandlerCall(pathparams, query, body, clientip, req, nothing)
    GC.@preserve call begin
        ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), f.objptr, pointer_from_objref(call))
    end
    return call.result::Response
end
