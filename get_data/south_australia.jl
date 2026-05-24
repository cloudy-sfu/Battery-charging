#=
south_australia.jl

Genie.jl backend that serves the generic `config_data.html` page and provides
SA1-specific data endpoints (battery list editing, supply/demand series from
`south_australia.db`, and JLD2 dataset export).

The HTML page is intentionally project-agnostic. All project-specific labels,
column names and time defaults are exposed via the `/config` endpoint.

Launch
======
    julia --project=. get_data/south_australia.jl
Then open http://127.0.0.1:8000.
=#

using Genie, Genie.Router, Genie.Renderer, Genie.Renderer.Json, Genie.Requests
using SQLite
using DataFrames
using Dates
using JLD2
using JSON3

include(joinpath(pwd(), "web_service.jl"))

const HTML_PATH  = joinpath(pwd(), "get_data", "config_data.html")
const DB_PATH    = joinpath(pwd(), "get_data", "south_australia.db")
const SQL_PATH   = joinpath(pwd(), "get_data", "sqls_south_australia", "get_supply_demand.sql")
const REGION_ID  = "SA1"
const EXPORT_DIR = joinpath(pwd(), "get_data", "datasets")

isdir(EXPORT_DIR) || mkpath(EXPORT_DIR)

# ---------------------------------------------------------------------------
# Project-specific config exposed to the front-end
# ---------------------------------------------------------------------------

const PAGE_CONFIG = Dict(
    "title"        => "South Australia Battery Dataset Builder",
    "region_label" => "region $(REGION_ID)",
    "series_help"  => """
        Load values are fetched for region <code>$(REGION_ID)</code> from
        <code>south_australia.db</code> using
        <code>sqls_south_australia/get_supply_demand.sql</code>.<br>
        Net demand load is demand minus the sum of supply sources.<br>
        Units are MWh per 30-minute interval as returned by AEMO. Sampling is
        30 minutes; rows are ordered from earliest to latest.<br>
        Times must be entered as <code>YYYY-MM-DD HH:MM:SS</code> (UTC,
        half-open interval <code>(start, end]</code>).
        """,
    "dataset_dir"  => EXPORT_DIR,
)

# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

open_db() = SQLite.DB(DB_PATH)

function load_batteries()::DataFrame
    db = open_db()
    DataFrame(SQLite.DBInterface.execute(
        db, "SELECT capacity, level, c_power, d_power, efficiency
              FROM batteries"))
end

function save_batteries(rows::AbstractVector)
    db = open_db()
    SQLite.transaction(db) do
        SQLite.DBInterface.execute(db, "DELETE FROM batteries")
        stmt = SQLite.Stmt(db, """
            INSERT INTO batteries
                (capacity, level, c_power, d_power, efficiency)
            VALUES (?, ?, ?, ?, ?)
        """)
        for r in rows
            SQLite.DBInterface.execute(stmt, (
                parse(Float64, string(r["capacity"])),
                parse(Float64, string(r["level"])),
                parse(Float64, string(r["c_power"])),
                parse(Float64, string(r["d_power"])),
                parse(Float64, string(r["efficiency"])),
            ))
        end
    end
end

"""
    fill_series!(v)

Linearly interpolate NaN values between known points, then back-fill before the
first known point and forward-fill after the last. Returns `false` if the
vector is entirely NaN.
"""
function fill_series!(v::AbstractVector{Float64})::Bool
    n = length(v)
    n == 0 && return false
    idxs = findall(!isnan, v)
    isempty(idxs) && return false
    # Interpolate between consecutive known points
    for k in 1:length(idxs)-1
        i, j = idxs[k], idxs[k+1]
        j == i + 1 && continue
        yi, yj = v[i], v[j]
        for m in i+1:j-1
            v[m] = yi + (yj - yi) * (m - i) / (j - i)
        end
    end
    # Back-fill before first known
    first_i = idxs[1]
    for m in 1:first_i-1
        v[m] = v[first_i]
    end
    # Forward-fill after last known
    last_i = idxs[end]
    for m in last_i+1:n
        v[m] = v[last_i]
    end
    true
end

function fetch_supply_demand(start_time::AbstractString,
                             end_time::AbstractString)
    sql = read(SQL_PATH, String)
    db = open_db()
    df = DataFrame(SQLite.DBInterface.execute(
        db, sql,
        (region = REGION_ID, start_time = start_time, end_time = end_time)))
    df.end_time = DateTime.(df.end_time, dateformat"yyyy-mm-dd HH:MM:SS")
    full_idx = DataFrame(end_time = collect(minimum(df.end_time):Minute(30):maximum(df.end_time)))
    df = leftjoin(full_idx, df, on = :end_time)
    sort!(df, :end_time)

    for col in propertynames(df)[2:end]
        v = Float64[x === missing || x === nothing ? NaN : Float64(x)
                    for x in df[!, col]]
        any_non_missing = fill_series!(v)
        if any_non_missing
            df[!, col] = v
        else
            select!(df, Not(col))
        end
    end
    supply_keys = propertynames(df)[3:end]  # exclude end_time, demand_load
    df, supply_keys
end

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

route("/") do
    Genie.Renderer.WebRenderable(read(HTML_PATH, String), :html) |> Genie.Renderer.respond
end

route("/config") do
    json(PAGE_CONFIG)
end

route("/api/browse_folders") do
    try
        path = String(get(Genie.Requests.getpayload(), "path", ""))
        if isempty(path) || path == "__HOME__"
            path = homedir()
        end
        path = abspath(path)
        while !isempty(path) && !isdir(path)
            parent = dirname(path)
            parent == path && (path = homedir(); break)
            path = parent
        end
        isdir(path) || return json(Dict("error" => "Cannot resolve directory"))
        dirs = String[]
        try
            for name in sort(readdir(path); by = lowercase)
                startswith(name, ".") && continue
                isdir(joinpath(path, name)) && push!(dirs, name)
            end
        catch
        end
        parent = dirname(path)
        parent_out = parent == path ? nothing : parent
        json(Dict("path" => path, "dirs" => dirs, "parent" => parent_out))
    catch e
        json(Dict("error" => sprint(showerror, e)))
    end
end

route("/api/create_folder", method = POST) do
    try
        body = JSON3.read(rawpayload())
        parent_path = String(get(body, "parent_path", ""))
        folder_name = strip(String(get(body, "folder_name", "")))
        isempty(parent_path) && (parent_path = homedir())
        parent_path = abspath(parent_path)
        isdir(parent_path) || return json(Dict("ok" => false, "error" => "Parent directory does not exist"))
        if isempty(folder_name) || folder_name in (".", "..") ||
           occursin('/', folder_name) || occursin('\\', folder_name)
            return json(Dict("ok" => false, "error" => "Invalid folder name"))
        end
        new_path = abspath(joinpath(parent_path, folder_name))
        startswith(new_path, parent_path) || return json(Dict("ok" => false, "error" => "Invalid folder path"))
        mkpath(new_path)
        json(Dict("ok" => true, "path" => new_path))
    catch e
        json(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

route("/batteries") do
    df = load_batteries()
    rows = [Dict(string(c) => row[c] for c in names(df)) for row in eachrow(df)]
    json(Dict("batteries" => rows))
end

route("/batteries", method = POST) do
    try
        body = JSON3.read(rawpayload())
        rows = [Dict(string(k) => v for (k, v) in pairs(r))
                for r in body["batteries"]]
        save_batteries(rows)
        json(Dict("ok" => true, "count" => length(rows)))
    catch e
        json(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

route("/series", method = POST) do
    try
        body = JSON3.read(rawpayload())
        df, supply_keys = fetch_supply_demand(String(body["start_time"]),
                                              String(body["end_time"]))
        out = Dict{String,Any}(
            "ok"          => true,
            "time"        => collect(df.end_time),
            "supply_keys" => supply_keys,
        )
        if :demand_load in propertynames(df)
            out["demand"] = collect(df.demand_load)
        end
        for k in supply_keys
            out[k] = collect(df[!, Symbol(k * "_load")])
        end
        json(out)
    catch e
        json(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

route("/export", method = POST) do
    try
        body = JSON3.read(rawpayload())
        batteries = load_batteries()
        load, _ = fetch_supply_demand(String(body["start_time"]),
                                      String(body["end_time"]))
        filename = String(get(body, "filename", "sa_dataset.jld2"))
        endswith(filename, ".jld2") || (filename *= ".jld2")
        filename = basename(filename)
        directory = String(get(body, "directory", EXPORT_DIR))
        isempty(strip(directory)) && (directory = EXPORT_DIR)
        isdir(directory) || mkpath(directory)
        path = joinpath(directory, filename)
        jldopen(path, "w") do file
            file["batteries"]  = batteries
            file["load"]       = load
            file["region"]     = REGION_ID
            file["start_time"] = String(body["start_time"])
            file["end_time"]   = String(body["end_time"])
        end
        json(Dict("ok" => true, "path" => path))
    catch e
        json(Dict("ok" => false, "error" => sprint(showerror, e)))
    end
end

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    Genie.config.run_as_server = true
    Genie.config.server_host   = "127.0.0.1"
    Genie.config.server_port   = find_available_port(1024)
    open_browser("http://$(Genie.config.server_host):$(Genie.config.server_port)")
    up(Genie.config.server_port, Genie.config.server_host; async = false)
end