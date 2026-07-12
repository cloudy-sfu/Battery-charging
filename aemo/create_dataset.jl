using ArgParse
using SQLite
using DataFrames
using Dates
using JLD2

function fill_series!(v::AbstractVector{Float64})::Bool
"""
    fill_series!(v)
    
Linearly interpolate NaN values between known points, then back-fill before the
first known point and forward-fill after the last. Returns `false` if the
vector is entirely NaN.
"""
    n = length(v)
    n == 0 && return false
    idxs = findall(!isnan, v)
    isempty(idxs) && return false
    for k in 1:length(idxs)-1
        i, j = idxs[k], idxs[k+1]
        j == i + 1 && continue
        yi, yj = v[i], v[j]
        for m in i+1:j-1
            v[m] = yi + (yj - yi) * (m - i) / (j - i)
        end
    end
    first_i = idxs[1]
    for m in 1:first_i-1
        v[m] = v[first_i]
    end
    last_i = idxs[end]
    for m in last_i+1:n
        v[m] = v[last_i]
    end
    true
end

function get_batteries(path::AbstractString)::DataFrame
"""
    get_batteries(path)

Read the battery group from a whitespace-delimited text file. Blank lines and
anything from a `#` to the end of a line are ignored (so rows may carry a
trailing comment). Each remaining row must hold five numeric fields:
`capacity`, `level`, `c_power`, `d_power`, `efficiency`.
"""
    rows = NTuple{5,Float64}[]
    for (lineno, raw) in enumerate(eachline(path))
        line = strip(first(split(raw, '#')))
        isempty(line) && continue
        fields = split(line)
        length(fields) == 5 ||
            error("$path line $lineno: expected 5 columns, got $(length(fields)): $(strip(raw))")
        push!(rows, ntuple(i -> parse(Float64, fields[i]), 5))
    end
    isempty(rows) && error("No battery rows found in $path.")
    DataFrame(
        capacity   = [r[1] for r in rows],
        level      = [r[2] for r in rows],
        c_power    = [r[3] for r in rows],
        d_power    = [r[4] for r in rows],
        efficiency = [r[5] for r in rows],
    )
end

function get_load_aemo(db_path::AbstractString, sql_path::AbstractString,
                             region::AbstractString,
                             start_time::AbstractString,
                             end_time::AbstractString)::DataFrame
    sql = read(sql_path, String)
    db = SQLite.DB(db_path)
    df = DataFrame(SQLite.DBInterface.execute(
        db, sql,
        (region = region, start_time = start_time, end_time = end_time)))
    nrow(df) == 0 && error("No load rows for region $region in ($start_time, $end_time].")
    df.end_time = DateTime.(df.end_time, dateformat"yyyy-mm-dd HH:MM:SS")
    full_idx = DataFrame(end_time = collect(minimum(df.end_time):Minute(30):maximum(df.end_time)))
    df = leftjoin(full_idx, df, on = :end_time)
    sort!(df, :end_time)

    for col in propertynames(df)[2:end]
        v = Float64[x === missing || x === nothing ? NaN : Float64(x)
                    for x in df[!, col]]
        if fill_series!(v)
            df[!, col] = v
        else
            select!(df, Not(col))
        end
    end
    df
end

s = ArgParseSettings()
@add_arg_table! s begin
    "--start_time"
        help = "Series start (exclusive), UTC \"YYYY-MM-DD HH:MM:SS\"."
        arg_type = String
        required = true
    "--end_time"
        help = "Series end (inclusive), UTC \"YYYY-MM-DD HH:MM:SS\"."
        arg_type = String
        required = true
    "--output_path"
        help = "Path to write the dataset (.jld2)."
        arg_type = String
        required = true
    "--region"
        help = "NEM region id."
        arg_type = String
        required = true
    "--db_path"
        help = "Path to the SQLite database."
        arg_type = String
        default = joinpath(pwd(), "aemo", "south_australia.db")
end
args = parse_args(s)

sql_path = joinpath(pwd(), "aemo", "sqls_south_australia", "get_supply_demand.sql")
batteries_path = joinpath(pwd(), "aemo", "batteries.txt")

batteries = get_batteries(batteries_path)

load = get_load_aemo(args["db_path"], sql_path, args["region"], args["start_time"], args["end_time"])

output_path = args["output_path"]
outdir = dirname(output_path)
isempty(outdir) || isdir(outdir) || mkpath(outdir)
jldopen(output_path, "w") do file
    file["batteries"]  = batteries
    file["load"]       = load
    file["region"]     = args["region"]
    file["start_time"] = args["start_time"]
    file["end_time"]   = args["end_time"]
end
println("Saved dataset to $output_path")
