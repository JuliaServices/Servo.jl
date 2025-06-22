loglevel(x::String) = x == "error" ? Logging.Error :
                     x == "warn"  ? Logging.Warn  :
                     x == "info"  ? Logging.Info  :
                                    Logging.Debug

lvlstr(lvl::Logging.LogLevel) = lvl >= Logging.Error ? "error" :
                                lvl >= Logging.Warn  ? "warn"  :
                                lvl >= Logging.Info  ? "info"  :
                                                       "debug"

struct JSONLogMessage{T}
    time::DateTime
    level::String
    msg::String
    _module::Union{String,Nothing}
    file::Union{String,Nothing}
    line::Union{Int,Nothing}
    group::Union{String,Nothing}
    id::Union{String,Nothing}
    kwargs
end

transform(::Type{String}, v) = string(v)
transform(::Type{Any}, v) = v

# Use key information, then lower to 2-arg transform
function transform(::Type{T}, key, v) where {T}
    key == :exception || return transform(T, v)
    if v isa Tuple && length(v) == 2 && v[1] isa Exception
        e, bt = v
        msg = sprint(Base.display_error, e, bt)
        return transform(T, msg)
    end
    return transform(T, sprint(showerror, v))
end

function JSONLogMessage{T}(args) where {T}
    JSONLogMessage{T}(
        Dates.now(Dates.UTC),
        lvlstr(args.level),
        args.message isa AbstractString ? args.message : string(args.message),
        args._module === nothing ? nothing : string(args._module),
        basename(args.file),
        args.line,
        args.group === nothing ? nothing : string(args.group),
        args.id === nothing ? nothing : string(args.id),
        args.kwargs
    )
end

struct JSONFormat <: Function
end

function (j::JSONFormat)(io, args)
    JSON.json(io, JSONLogMessage{String}(args))
    println(io)
    return nothing
end
