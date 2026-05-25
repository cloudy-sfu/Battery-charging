using ArgParse
using Dates
using JLD2
using DataFrames
using JuMP
using HiGHS

# %% Parse CLI arguments
s = ArgParseSettings()
@add_arg_table! s begin
    "--input_path"
        help = "Path to input dataset (.jld2) containing `batteries` and `load`."
        arg_type = String
        required = true
    "--output_path"
        help = "Path to write solver result (.jld2)."
        arg_type = String
        required = true
    "--timeout"
        help = "Optional solver time limit in seconds."
        arg_type = Float64
        default = 0.0
end
args = parse_args(s)
input_path  = args["input_path"]
output_path = args["output_path"]
timeout     = args["timeout"]

# %% Load dataset
batteries, load = jldopen(input_path, "r") do file
    file["batteries"], file["load"]
end

# %% Compute net demand
# load column 1: end_time; column 2: demand; column 3+: supplies.
# Net demand = demand - sum(supplies). Column names are not hard-coded.
demand_col = Float64.(load[!, 2])
supply_sum = ncol(load) >= 3 ?
    sum(Float64.(load[!, j]) for j in 3:ncol(load)) :
    zeros(Float64, nrow(load))
D = demand_col .- supply_sum
end_time = collect(load[!, 1])

# Infer sampling step (hours) from end_time. Require a unique spacing.
diffs = unique(diff(end_time))
length(diffs) == 1 || error("Non-uniform sampling in load[:,1]: found $(length(diffs)) distinct steps: $diffs")
Δt = isa(diffs[1], Period) ? Dates.value(Second(diffs[1])) / 3_600 : float(diffs[1])
Δt > 0 || error("Non-positive sampling step inferred from end_time: $Δt")
println("Loaded dataset: $(nrow(batteries)) batteries, $(length(D)) time slots, Δt = $Δt h.")

# %% Battery parameters
C  = Float64.(batteries.capacity)
L  = Float64.(batteries.level)      # fractional initial level (0~1)
Ip = Float64.(batteries.c_power)
Op = Float64.(batteries.d_power)
E  = Float64.(batteries.efficiency)
A0 = L .* C
m = length(C)
n = length(D)

# %% Build MILP
model = Model(HiGHS.Optimizer)
timeout > 0 && set_time_limit_sec(model, timeout)

@variable(model, t[1:n] >= 0)
@variable(model, P[1:m, 1:n] >= 0)
@variable(model, H[1:m, 1:n] >= 0)
@variable(model, A[1:m, 1:n+1] >= 0)
@variable(model, Sc[1:m, 1:n], Bin)
@variable(model, Sd[1:m, 1:n], Bin)

@objective(model, Min, sum(t))

@constraint(model, [i = 1:m], A[i, 1] == A0[i])
@constraint(model, [j = 1:n], D[j] - sum(P[i, j] for i in 1:m) <= t[j])
@constraint(model, [i = 1:m, j = 1:n],
    A[i, j] + (E[i] * H[i, j] - P[i, j]) * Δt == A[i, j + 1])
@constraint(model, [i = 1:m, j = 1:n], H[i, j] <= Ip[i] * Sc[i, j])
@constraint(model, [i = 1:m, j = 1:n], P[i, j] <= Op[i] * Sd[i, j])
@constraint(model, [i = 1:m, j = 1:n], Sc[i, j] + Sd[i, j] <= 1)
@constraint(model, [i = 1:m, j = 1:n], A[i, j] <= C[i])
@constraint(model, [i = 1:m, j = 1:n], P[i, j] * Δt <= A[i, j])
@constraint(model, [j = 1:n], sum(H[i, j] for i in 1:m) <= max(0.0, -D[j]))

# %% Solve
optimize!(model)
status = termination_status(model)
has_vals = primal_status(model) == MOI.FEASIBLE_POINT
println("Status: ", status,
        " | objective: ", has_vals ? objective_value(model) : NaN)

# %% Save all outputs to JLD2
outdir = dirname(output_path)
isempty(outdir) || isdir(outdir) || mkpath(outdir)
jldopen(output_path, "w") do file
    file["termination_status"] = string(status)
    file["primal_status"]      = string(primal_status(model))
    file["objective"]          = has_vals ? objective_value(model) : NaN
    file["batteries"]          = batteries
    file["end_time"]           = end_time
    file["demand"]             = D
    file["A"]  = has_vals ? value.(A)  : zeros(m, n + 1)
    file["P"]  = has_vals ? value.(P)  : zeros(m, n)
    file["H"]  = has_vals ? value.(H)  : zeros(m, n)
    file["Sc"] = has_vals ? value.(Sc) : zeros(m, n)
    file["Sd"] = has_vals ? value.(Sd) : zeros(m, n)
    file["t"]  = has_vals ? value.(t)  : zeros(n)
end
println("Saved solution to $output_path")
