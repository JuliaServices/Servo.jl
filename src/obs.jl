module Obs

using StructUtils, JSON, Dates, Printf, Parsers

import ..Done, ..isdone, ..done!

tr(x::Float64) = round(Int, x)

function time_print(io::IO, elapsedtime, bytes=0, gctime=0, allocs=0, lock_conflicts=0, compile_time=0, recompile_time=0, newline=false;
                    msg::Union{String,Nothing}=nothing)
    timestr = Base.Ryu.writefixed(Float64(elapsedtime/1e9), 6)
    if allocs < 0
        allocs = 0
    end
    seconds = elapsedtime / 1e9
    str = sprint() do io
        if msg isa String
            print(io, msg, ": ")
        else
            print(io, length(timestr) < 10 ? (" "^(10 - length(timestr))) : "")
        end
        if seconds < 1e-6
            print_rounded(io, seconds*1e9, 3); print(io, " ns")
        elseif seconds < 1e-3
            @printf io "%.3f μs" seconds*1e6
        elseif seconds < 1
            @printf io "%.3f ms" seconds*1e3
        else
            @printf io "%.3f s" seconds
        end
        parens = bytes != 0 || allocs != 0 || gctime > 0 || lock_conflicts > 0 || compile_time > 0
        parens && print(io, " (")
        if bytes != 0 || allocs != 0
            allocs, ma = Base.prettyprint_getunits(allocs, length(Base._cnt_units), Int64(1000))
            if ma == 1
                print(io, Int(allocs), Base._cnt_units[ma], allocs==1 ? " allocation: " : " allocations: ")
            else
                print(io, Base.Ryu.writefixed(Float64(allocs), 2), Base._cnt_units[ma], " allocations: ")
            end
            print(io, Base.format_bytes(bytes))
        end
        if gctime > 0
            if bytes != 0 || allocs != 0
                print(io, ", ")
            end
            print(io, Base.Ryu.writefixed(Float64(100*gctime/elapsedtime), 2), "% gc time")
        end
        if lock_conflicts > 0
            if bytes != 0 || allocs != 0 || gctime > 0
                print(io, ", ")
            end
            plural = lock_conflicts == 1 ? "" : "s"
            print(io, lock_conflicts, " lock conflict$plural")
        end
        if compile_time > 0
            if bytes != 0 || allocs != 0 || gctime > 0 || lock_conflicts > 0
                print(io, ", ")
            end
            print(io, Base.Ryu.writefixed(Float64(100*compile_time/elapsedtime), 2), "% compilation time")
        end
        if recompile_time > 0
            perc = Float64(100 * recompile_time / compile_time)
            # use "<1" to avoid the confusing UX of reporting 0% when it's >0%
            print(io, ": ", perc < 1 ? "<1" : Base.Ryu.writefixed(perc, 0), "% of which was recompilation")
        end
        parens && print(io, ")")
        newline && print(io, "\n")
    end
    print(io, str)
    nothing
end

function print_rounded(@nospecialize(io::IO), x::Float64, digits::Int)
    1 ≤ digits ≤ 20 || throw(ArgumentError("digits must be between 1 and 20"))
    if x == 0
        print(io, '0')
    elseif 0 < x < 1/10^digits
        print(io, "<0.", '0'^(digits-1), "1")
    else
        print(io, Base.Ryu.writefixed(x, digits))
    end
end

# prints a Float64 w/ 2 significant digits and a % sign
function print_percent(io, x::Float64)
    @nospecialize
    return print_rounded(io, x*100, 2), print(io, "%")
end

function print_percent(io, numerator, denominator, show_num_denom::Bool=true)
    @nospecialize
    show_num_denom && print(io, numerator, " / ", denominator, " = "),
    return print_percent(io, denominator == 0 ? NaN : numerator / denominator)
end

function print_bytes(io, num, den, show_num_denom::Bool=true)
    @nospecialize
    show_num_denom && print(io, num, " / ", den, " = ")
    ratio = den == 0 ? NaN : (num / den)
    if isfinite(ratio)
        return print(io, Base.format_bytes(round(Int, ratio)))
    else
        return print(io, "NaN")
    end
end

quot(ex::Expr) = Expr(:call, :(=>), Meta.quot(ex.args[2]), Meta.quot(ex.args[3]))
const Per = Union{Nothing,Pair{Nothing,Symbol},Pair{Symbol,Symbol}}

@defaults mutable struct Count
    count::Int = 0
    per::Per = nothing
end

Base.show(io::IO, c::Count) = ispresent(METRICS, c.per) ? print_percent(io, c.count, metric(METRICS, c.per).count) : print(io, "$(c.count)")
reset!(c::Count) = c.count = 0
ispresent(c::Count) = c.count > 0

macro count(name, n)
    quote
        @lock Obs.METRICS.lock begin
            cnt = get!(() -> Obs.Count(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing), $(Meta.quot(name)))::Obs.Count
            cnt.count += $(esc(n))
        end
    end
end

macro count(group, name, n)
    quote
        @lock Obs.METRICS.lock begin
            cnt = get!(() -> Obs.Count(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Count
            cnt.count += $(esc(n))
        end
    end
end

macro count(group, name, per, n)
    quote
        @lock Obs.METRICS.lock begin
            cnt = get!(() -> Obs.Count(0, $(quot(per))), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Count
            cnt.count += $(esc(n))
        end
    end
end

@defaults mutable struct Bytes
    bytes::Int = 0
    per::Per = nothing
end

Base.show(io::IO, b::Bytes) = ispresent(METRICS, b.per) ? print_bytes(io, b.bytes, metric(METRICS, b.per).count) : print(io, Base.format_bytes(b.bytes))
reset!(b::Bytes) = b.bytes = 0
ispresent(b::Bytes) = b.bytes > 0

macro bytes(name, n)
    quote
        @lock Obs.METRICS.lock begin
            b = get!(() -> Obs.Bytes(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing), $(Meta.quot(name)))::Obs.Bytes
            b.bytes += $(esc(n))
        end
    end
end

macro bytes(group, name, n)
    quote
        @lock Obs.METRICS.lock begin
            b = get!(() -> Obs.Bytes(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Bytes
            b.bytes += $(esc(n))
        end
    end
end

macro bytes(group, name, per, n)
    quote
        @lock Obs.METRICS.lock begin
            b = get!(() -> Obs.Bytes(0, $(quot(per))), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Bytes
            b.bytes += $(esc(n))
        end
    end
end

Base.:(+)(a::Base.GC_Diff, b::Base.GC_Diff) = Base.GC_Diff(
    a.allocd + b.allocd,
    a.malloc + b.malloc,
    a.realloc + b.realloc,
    a.poolalloc + b.poolalloc,
    a.bigalloc + b.bigalloc,
    a.freecall + b.freecall,
    a.total_time + b.total_time,
    a.pause + b.pause,
    a.full_sweep + b.full_sweep
)

@defaults mutable struct Time
    time::Float64 = 0.0
    bytes::Int = 0
    gctime::Float64 = 0.0
    gcstats::Base.GC_Diff = Base.GC_Diff(Base.gc_num(), Base.gc_num())
    lock_conflicts::Int = 0
    compile_time::Float64 = 0.0
    recompile_time::Float64 = 0.0
    per::Per = nothing
end

function Time(per::Per)
    t = Time()
    t.per = per
    return t
end

Base.copy(t::Time) = Time(t.time, t.bytes, t.gctime, t.gcstats, t.lock_conflicts, t.compile_time, t.recompile_time, t.per)

function update!(t::Time, nmt::NamedTuple)
    t.time += nmt.time * 1e9
    t.bytes += nmt.bytes
    t.gctime += nmt.gctime
    t.gcstats += nmt.gcstats
    t.lock_conflicts += nmt.lock_conflicts
    t.compile_time += nmt.compile_time * 1e9
    t.recompile_time += nmt.recompile_time * 1e9
    return
end

function Base.show(io::IO, t::Time)
    if ispresent(METRICS, t.per)
        d = metric(METRICS, t.per).count
        time_print(io, t.time / d, tr(t.bytes / d), t.gctime / d, tr(Base.gc_alloc_count(t.gcstats) / d), tr(t.lock_conflicts / d), t.compile_time / d, t.recompile_time / d, false)
        return
    end
    time_print(io, t.time, t.bytes, t.gctime, Base.gc_alloc_count(t.gcstats), t.lock_conflicts, t.compile_time, t.recompile_time, false)
end

function reset!(t::Time)
    t.time = 0.0
    t.bytes = 0
    t.gctime = 0.0
    t.gcstats = Base.GC_Diff(Base.gc_num(), Base.gc_num())
    t.lock_conflicts = 0
    t.compile_time = 0.0
    t.recompile_time = 0.0
end
ispresent(t::Time) = t.time > 0.0

macro time(name, ex)
    quote
        stats = @timed begin
            $(esc(ex))
        end
        @lock Obs.METRICS.lock begin
            t = get!(() -> Obs.Time(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing), $(Meta.quot(name)))::Obs.Time
            Obs.update!(t, stats)
        end
        stats.value
    end
end

macro time(group, name, ex)
    quote
        stats = @timed begin
            $(esc(ex))
        end
        @lock Obs.METRICS.lock begin
            t = get!(() -> Obs.Time(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Time
            Obs.update!(t, stats)
        end
        stats.value
    end
end

macro time(group, name, per, ex)
    quote
        stats = @timed begin
            $(esc(ex))
        end
        @lock Obs.METRICS.lock begin
            t = get!(() -> Obs.Time($(quot(per))), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.Time
            Obs.update!(t, stats)
        end
        stats.value
    end
end

@defaults mutable struct Value{T}
    value::T
end

Base.show(io::IO, v::Value) = print(io, v.value)
reset!(v::Value{T}) where {T} = v.value = T(0)
reset!(v::Value{String}) = v.value = ""
ispresent(v::Value{T}) where {T} = v.value != T(0)
ispresent(v::Value{String}) = !isempty(v.value)

macro value(name, x)
    quote
        @lock Obs.METRICS.lock begin
            get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing)[$(Meta.quot(name))] = Obs.Value($(esc(x)))
        end
    end
end

macro value(group, name, x)
    quote
        @lock Obs.METRICS.lock begin
            get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group)))[$(Meta.quot(name))] = Obs.Value($(esc(x)))
        end
    end
end

@defaults mutable struct ValueSet
    values::Set{String} = Set{String}()
end

Base.show(io::IO, vs::ValueSet) = print(io, vs.values)
reset!(vs::ValueSet) = empty!(vs.values)
ispresent(vs::ValueSet) = !isempty(vs.values)

macro valueset(name, x)
    quote
        @lock Obs.METRICS.lock begin
            set = get!(() -> Obs.ValueSet(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing), $(Meta.quot(name)))::Obs.ValueSet
            push!(set.values, $(esc(x)))
        end
    end
end

macro valueset(group, name, x)
    quote
        @lock Obs.METRICS.lock begin
            set = get!(() -> Obs.ValueSet(), get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group))), $(Meta.quot(name)))::Obs.ValueSet
            push!(set.values, $(esc(x)))
        end
    end
end

struct Every
    f::Function
end

Base.show(io::IO, e::Every) = show(io, e.f())
ispresent(e::Every) = true
reset!(::Every) = nothing

macro every(name, every)
    quote
        @lock Obs.METRICS.lock begin
            get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, nothing)[$(Meta.quot(name))] = Obs.Every(() -> $(esc(every)))
        end
    end
end

macro every(group, name, every)
    quote
        @lock Obs.METRICS.lock begin
            get!(() -> JSON.Object{Symbol,Any}(), Obs.METRICS.metrics, $(Meta.quot(group)))[$(Meta.quot(name))] = Obs.Every(() -> $(esc(every)))
        end
    end
end

function everyper(per::Per)
    ev = copy(metric(METRICS, nothing => :every))
    ev.per = per
    return ev
end

struct Metrics
    lock::ReentrantLock
    # group => metric => value
    metrics::JSON.Object{Union{Symbol,Nothing},JSON.Object{Symbol,Any}}
end

# only call after calling ispresent
metric(m::Metrics, nm::Per) = @lock m.lock m.metrics[nm.first][nm.second]
Base.isempty(m::Metrics) = @lock m.lock isempty(m.metrics)
ispresent(m::Metrics, nm::Per) = nm !== nothing && @lock m.lock haskey(m.metrics, nm.first) && haskey(m.metrics[nm.first], nm.second) && ispresent(m.metrics[nm.first][nm.second])

function Base.show(io::IO, m::Metrics)
    @lock m.lock begin
        for (group, metrics) in m.metrics
            group !== nothing && print(io, "Group: ", group, "\n")
            for (k, v) in metrics
                ispresent(v) || continue
                print(io, "  ", k, " => ")
                show(io, v)
                println(io)
            end
        end
        # now reset metrics
        for (_, metrics) in m.metrics
            for (_, v) in metrics
                reset!(v)
            end
        end
    end
end

const METRICS = Metrics(ReentrantLock(), JSON.Object{Union{Symbol,Nothing},JSON.Object{Symbol,Any}}(nothing => JSON.Object{Symbol,Any}()))

struct MetricsLoggingTask
    done::Done
    task::Task
end

Base.close(t::MetricsLoggingTask) = done!(t.done)

function start_metric_logging_task(every::Dates.Period)
    done = Done()
    t = errormonitor(Threads.@spawn begin
        while !isdone(done)
            # every `every` period, log metrics in metrics store
            Obs.@time every sleep(every)
            if !isempty(METRICS)
                Obs.@value now Dates.now(Dates.UTC)
                Obs.@value processMemoryRss Base.format_bytes(Int(Sys.maxrss()))
                @info "" duration = every metrics = METRICS
            end
        end
    end)
    return MetricsLoggingTask(done, t)
end

end # module