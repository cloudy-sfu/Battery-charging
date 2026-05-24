#=
south_australia_small.jl

Build a reduced SA1 dataset for fast A/B testing of the MILP solver
(jsLPSolver in particular). Keeps the same on-disk JLD2 layout as the
`/export` route in `south_australia.jl`, but with:

    * 2 batteries (first two rows of the `batteries` table)
    * 12 hours of half-hourly load (24 time slots)

Run:
    julia --project=. get_data/south_australia_small.jl
=#

include(joinpath(pwd(), "get_data", "south_australia.jl"))

using JLD2

const START_TIME = "2026-05-13 18:00"
const END_TIME   = "2026-05-14 18:00"
const N_BATTS    = 2
const DATASET_DIR = joinpath(pwd(), "get_data", "datasets")
isdir(DATASET_DIR) || mkpath(DATASET_DIR)

const OUT_PATH   = joinpath(DATASET_DIR, "south_australia_small.jld2")

"""
    resample_hourly(df)

Aggregate a half-hourly load DataFrame to 1-hour resolution. The `end_time`
column is taken from the later row of each pair; all other (numeric) columns
are summed, since values are MWh per interval.
"""
function resample_hourly(df::DataFrame)::DataFrame
    n = nrow(df)
    n >= 2 || return df
    # Align so the first kept row ends on a full hour.
    start = minute(df.end_time[1]) == 0 ? 2 : 1
    cols = propertynames(df)
    out = DataFrame()
    out.end_time = df.end_time[start+1:2:n]
    for c in cols
        c === :end_time && continue
        v = df[!, c]
        out[!, c] = [v[i-1] + v[i] for i in start+1:2:n]
    end
    out
end

batteries = first(load_batteries(), N_BATTS)
batteries[!, :level] .= 0.01
load, _   = fetch_supply_demand(START_TIME, END_TIME)
load      = resample_hourly(load)

println(batteries)
println(load)

jldopen(OUT_PATH, "w") do file
    file["batteries"]  = batteries
    file["load"]       = load
    file["region"]     = REGION_ID
    file["start_time"] = START_TIME
    file["end_time"]   = END_TIME
end

println("Saved dataset to $OUT_PATH")
