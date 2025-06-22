# json_middleware
struct Arg
    ispath::Bool
    isquery::Bool # based on if a default value is provided
    name::String
    type::Type
    default::Any
end

function parseargs(path, fexpr)
    @assert fexpr.head == :function "Only functions can be annotated with @GET, @POST, @PUT, or @DELETE"
    pathparams = [x.captures[1] for x in eachmatch(r"\{(\w+)\}", path)]
    sig = fexpr.args[1]
    argexprs = @view sig.args[2:end]
    
    # Collect all arguments (including those in :parameters)
    all_args = Expr[]
    
    for argexpr in argexprs
        if argexpr isa Symbol
            # type-less argument as path param or body
            nm = String(argexpr)
            if nm in pathparams
                push!(all_args, :(Servo.Arg(true, false, $nm, Any, nothing)))
            else
                push!(all_args, :(Servo.Arg(false, false, $nm, Any, nothing)))
            end
        elseif argexpr.head == :parameters
            # Handle multiple keyword arguments in :parameters
            for kw_expr in argexpr.args
                if kw_expr.head == :kw
                    argex, default = kw_expr.args
                    if argex isa Symbol
                        nm = String(argex)
                        push!(all_args, :(Servo.Arg(false, true, $nm, Any, $default)))
                    else
                        nm = String(argex.args[1])
                        push!(all_args, :(Servo.Arg(false, true, $nm, $(argex.args[2]), $default)))
                    end
                end
            end
        elseif argexpr.head == :kw
            # single keyword argument as query param
            argex, default = argexpr.args
            if argex isa Symbol
                nm = String(argex)
                push!(all_args, :(Servo.Arg(false, true, $nm, Any, $default)))
            else
                nm = String(argex.args[1])
                push!(all_args, :(Servo.Arg(false, true, $nm, $(argex.args[2]), $default)))
            end
        else
            # type-annotated argument as path param or body
            nm = String(argexpr.args[1])
            if nm in pathparams
                push!(all_args, :(Servo.Arg(true, false, $nm, $(argexpr.args[2]), nothing)))
            else
                push!(all_args, :(Servo.Arg(false, false, $nm, $(argexpr.args[2]), nothing)))
            end
        end
    end
    
    return all_args
end

_string(x::Union{AbstractString, AbstractVector{UInt8}}) = String(x)
_string(x::AbstractString) = string(x)

function infer(arg::Arg, val, quiet::Bool = false)
    try
        if arg.type == Int
            return parse(Int, val)
        elseif arg.type == Float64
            return parse(Float64, val)
        elseif arg.type == Bool
            return val in ("t", "T", "1", "true") ? true :
                   val in ("f", "F", "0", "false") ? false : parse(Bool, val)
        elseif arg.type == String
            return _string(val)
        elseif arg.type == Vector{Int}
            return map(x -> parse(Int, x), split(val, ","))
        elseif arg.type == Vector{Float64}
            return map(x -> parse(Float64, x), split(val, ","))
        elseif arg.type == Vector{Bool}
            return map(x -> parse(Bool, x), split(val, ","))
        elseif arg.type == Vector{String}
            return map(_string, split(val, ","))
        else
            # try to infer val, first Bool, then Int, then Float64, otherwise String
            if val == "true"
                return true
            elseif val == "false"
                return false
            elseif match(r"^[-+]?\d+$", val) !== nothing
                return parse(Int, val)
            elseif match(r"^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$", val) !== nothing
                return parse(Float64, val)
            else
                return _string(val)
            end
        end
    catch e
        quiet || @error "failed to infer/cast argument to type: $(arg.type) from value: $val" exception=(e, catch_backtrace())
        return val
    end
end

function extractargs(fargs::Vector{Arg}, args, req::HTTP.Request)
    resize!(args, length(fargs))
    for (i, arg) in enumerate(fargs)
        if arg.ispath
            args[i] = infer(arg, HTTP.getparams(req)[arg.name])
        elseif arg.isquery
            # check if arg is in query params
            u = HTTP.URI(req.target)
            queryparams = HTTP.URIs.queryparampairs(u)
            found = false
            for (k, v) in queryparams
                if k == arg.name
                    args[i] = infer(arg, v)
                    found = true
                    break
                end
            end
            # if not found, use default value
            found || (args[i] = arg.default)
        else
            # otherwise, materialize from request body
            args[i] = JSON.parse(req.body, arg.type)
        end
    end
    return args
end

function json_middleware(handler, fargs::Vector{Arg})
    args = []
    return function(req::HTTP.Request)
        argvals = extractargs(fargs, args, req)
        pos_args = []
        kw_pairs = []
        for (i, arg) in enumerate(fargs)
            if arg.isquery
                push!(kw_pairs, (Symbol(arg.name), argvals[i]))
            else
                push!(pos_args, argvals[i])
            end
        end
        kwargs = (; kw_pairs...)
        ret = if !isempty(pos_args) && !isempty(kw_pairs)
            handler(pos_args...; kwargs...)
        elseif !isempty(pos_args)
            handler(pos_args...)
        else
            handler(; kwargs...)
        end
        empty!(args)
        return HTTP.Response(200, JSON.json(ret))
    end
end
