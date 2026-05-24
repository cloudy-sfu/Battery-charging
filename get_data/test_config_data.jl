#=
artificial_random.jl

Genie.jl backend that serves the generic `config_data.html` page and provides
artificial random data generation for demand and supply.

Launch
======
    julia --project=. get_data/artificial_random.jl
=#

using Genie, Genie.Router, Genie.Renderer, Genie.Renderer.Json, Genie.Requests
using SQLite
using DataFrames
using Dates
using JLD2
using JSON3
using Random

include(joinpath(pwd(), "web_service.jl"))

const HTML_PATH  = joinpath(pwd(), "get_data", "config_data.html")
const DB_PATH    = joinpath(pwd(), "get_data", "artificial_random.db")
const EXPORT_DIR = joinpath(pwd(), "get_data", "datasets")

isdir(EXPORT_DIR) || mkpath(EXPORT_DIR)

# ---------------------------------------------------------------------------
# Project-specific config exposed to the front-end
# ---------------------------------------------------------------------------

const PAGE_CONFIG = Dict(
    "title"        => "Artificial Random Data Builder",
    "region_label" => "(Random Simulation)",
    "series_help"  => "Generates 1 demand and 2 supplies randomly. The sum of expectations of the two supplies equals the expectation of the demand. Resolution is 30 minutes.",
    "dataset_dir"  => EXPORT_DIR,
)

# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

function open_db()
    db = SQLite.DB(DB_PATH)
    SQLite.DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS batteries (capacity REAL, level REAL, c_power REAL, d_power REAL, efficiency REAL)")
    return db
end

function load_batteries()::DataFrame
    db = open_db()
    DataFrame(SQLite.DBInterface.execute(
        db, "SELECT capacity, level, c_power, d_power, efficiency FROM batteries"))
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

function fetch_supply_demand(start_time::AbstractString, end_time::AbstractString)
    # The browser sends datetime-local values like "2026-05-13T10:00"
    dt_start = DateTime(start_time[1:16])
    dt_end   = DateTime(end_time[1:16])
    
    t_idx = collect(dt_start:Minute(30):dt_end)
    n = length(t_idx)

    # Random generation
    # Supply 1 mean = 40, Supply 2 mean = 60, Demand mean = 100
    # Expected supplies = Expected demand
    supply1 = 40.0 .+ 5.0 .* randn(n)
    supply2 = 60.0 .+ 10.0 .* randn(n)
    demand  = 100.0 .+ 11.18 .* randn(n) # sqrt(5^2 + 10^2) ≈ 11.18

    df = DataFrame(end_time = t_idx, demand_load = demand, supply1 = supply1, supply2 = supply2)
    supply_keys = [:supply1, :supply2]

    return df, supply_keys
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
        supply_names = [String(k) for k in supply_keys]
        out = Dict{String,Any}(
            "ok"          => true,
            "time"        => [Dates.format(t, dateformat"yyyy-mm-dd HH:MM:SS") for t in df.end_time],
            "supply_keys" => supply_names,
        )
        if :demand_load in propertynames(df)
            out["demand"] = collect(df.demand_load)
        end
        for (name, sym) in zip(supply_names, supply_keys)
            out[name] = collect(df[!, sym])
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
        filename = String(get(body, "filename", "random_dataset.jld2"))
        endswith(filename, ".jld2") || (filename *= ".jld2")
        filename = basename(filename)
        directory = String(get(body, "directory", EXPORT_DIR))
        isempty(strip(directory)) && (directory = EXPORT_DIR)
        isdir(directory) || mkpath(directory)
        path = joinpath(directory, filename)
        jldopen(path, "w") do file
            file["batteries"]  = batteries
            file["load"]       = load
            file["region"]     = "random"
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