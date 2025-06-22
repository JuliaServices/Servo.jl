const POSTGRES_POOL = ConcurrentUtilities.Pool{Postgres.Connection}()
const CURRENT_POSTGRES_CONN = ScopedValue{Postgres.Connection}()

function postgres(; host=getConfig("postgres")["host"], user=getConfig("postgres")["user"], password=getConfig("postgres")["password"], dbname=getConfig("postgres")["dbname"])
    return DBInterface.connect(Postgres.Connection, host, user, password; dbname=dbname, port=5432)
end

function _isopen(x)
    isopen(x) && return true
    close(x)
    return false
end

function withpostgres(f; forcenew::Bool=false)
    if !forcenew && isassigned(CURRENT_POSTGRES_CONN)
        return f(CURRENT_POSTGRES_CONN[])
    end
    #TODO: it'd be nice to verify that the connection from the pool has the same configs as we currently expect
    conn = acquire(postgres, POSTGRES_POOL; isvalid=isopen, forcenew)
    try
        return @with CURRENT_POSTGRES_CONN => conn f(conn)
    catch
        close(conn)
        conn = nothing
        rethrow()
    finally
        release(POSTGRES_POOL, conn)
    end
end

function closepostgres!()
    ConcurrentUtilities.drain!(POSTGRES_POOL)
end

const IN_TRANSACTION = ScopedValue{Bool}(false)

function transaction(f; mock::Bool=false)
    (IN_TRANSACTION[] || mock) && return f()
    @with IN_TRANSACTION => true begin
        withpostgres() do conn
            DBInterface.transaction(conn) do
                return f()
            end
        end
    end
end

# used to annotate a function definition as transactional
# wraps function body in a Servo.transaction block
macro transactional(ex)
    @assert ex.head == :function
    @assert ex.args[2].head == :block
    doexpr = Expr(:do, :(Servo.transaction(; mock=(@isdefined(mock) ? mock : false))), :(() -> $(ex.args[2])))
    ex.args[2] = doexpr
    return esc(ex)
end

const RES = Ref{Any}(nothing)

function sqlquery(query::String)
    withpostgres() do conn
        try
            file = nothing
            # if query ends with: `| [file.csv]`, then split that off from sql query
            # and write the result to that file
            if occursin(r"\| .+\.csv$", query)
                file = replace(match(r"\| .+\.csv$", query).match, r"\| " => "")
                query = replace(query, r"\| .+\.csv$" => "")
            end
            res = DBInterface.execute(conn, query)
            if file !== nothing
                writecsv(file, res)
            end
            RES[] = res
            pretty_table(res)
        catch e
            @error "Error executing query" exception=(e, catch_backtrace())
        end
    end
end

function getcell(x)
    str = string(x)
    # if string has '|' or '\n', then wrap it in quotes
    return occursin(r"[\||\n]", str) ? "\"$(str)\"" : str
end

function writecsv(file, data)
    sch = Tables.schema(data)
    open(file, "w") do io
        write(io, join(map(getcell, sch.names), "|") * "\n")
        for row in data
            join(io, map(x -> getcell(getproperty(row, x)), sch.names), "|")
            write(io, "\n")
        end
    end
end