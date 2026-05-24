#=
visualization.jl

Loads a solver result produced by `solve.jl` (JLD2) and writes a
self-contained HTML report that renders the same three ECharts charts as
`index.html` / `visualization.js`:
  1. Charging history per battery (remaining energy with colored phases)
  2. Power history (charging negative / discharging positive) per battery
  3. Served electricity (stacked bar of discharge vs. demand)

Usage:
    julia --project=. visualization.jl \
        --input_path  results/south_australia_small_solution.jld2 \
        --output_path results/south_australia_small_solution.html
=#

using ArgParse
using JLD2
using JSON
using DataFrames

s = ArgParseSettings()
@add_arg_table! s begin
    "--input_path"
        help = "Path to solver result (.jld2) produced by solve.jl."
        arg_type = String
        required = true
    "--output_path"
        help = "Path to write HTML report."
        arg_type = String
        required = true
end
args = parse_args(s)
input_path  = args["input_path"]
output_path = args["output_path"]

# %% Load solution
batteries, A, P, H, Sc, Sd, t_slack, D, end_time, status_str, primal_str, obj =
    jldopen(input_path, "r") do f
        f["batteries"], f["A"], f["P"], f["H"], f["Sc"], f["Sd"], f["t"],
        f["demand"], f["end_time"], f["termination_status"],
        f["primal_status"], f["objective"]
    end

energy_capacity = Float64.(batteries.capacity)
m = size(A, 1)
n = size(A, 2) - 1

# Build per-battery JSON-friendly data
A_rows  = [collect(A[i, :])  for i in 1:m]      # length n+1
P_rows  = [collect(P[i, :])  for i in 1:m]
H_rows  = [collect(H[i, :])  for i in 1:m]
Sc_rows = [collect(Sc[i, :]) for i in 1:m]
Sd_rows = [collect(Sd[i, :]) for i in 1:m]

payload = Dict(
    "m" => m,
    "n" => n,
    "A"  => A_rows,
    "P"  => P_rows,
    "H"  => H_rows,
    "Sc" => Sc_rows,
    "Sd" => Sd_rows,
    "t" => collect(t_slack),
    "demand" => collect(D),
    "end_time" => string.(end_time),
    "energy_capacity" => energy_capacity,
    "status" => status_str,
    "primal_status" => primal_str,
    "objective" => isfinite(obj) ? obj : nothing,
)

data_json = JSON.json(payload)

# %% Render HTML template
template_path = joinpath(@__DIR__, "report.html")
template = read(template_path, String)
occursin("{{SOLUTION_JSON}}", template) ||
    error("Template $template_path is missing the {{SOLUTION_JSON}} placeholder.")
html = replace(template, "{{SOLUTION_JSON}}" => data_json)

outdir = dirname(output_path)
isempty(outdir) || isdir(outdir) || mkpath(outdir)
open(output_path, "w") do io
    write(io, html)
end
