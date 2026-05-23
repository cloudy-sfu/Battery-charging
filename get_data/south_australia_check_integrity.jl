using SQLite
using DataFrames
using Dates

const DB_PATH = joinpath(pwd(), "get_data", "south_australia.db")
const SQL_DIR = joinpath(pwd(), "get_data", "sqls_south_australia")

const CHECKS = [
    ("dispatched_scada_completion.sql", Minute(5), "fetch_aemo_dispatched_scada"),
    ("historical_demand_completion.sql", Minute(30), "fetch_aemo_hist_demand"),
    ("next_day_gen_completion.sql", Minute(5), "fetch_aemo_next_day_gen"),
]

db = SQLite.DB(DB_PATH)
for (sql_file, sampling_frequency, job_name) in CHECKS
    sql = read(joinpath(SQL_DIR, sql_file), String)
    df = DataFrame(SQLite.DBInterface.execute(db, sql))
    nrows = nrow(df)
    if nrows == 0
        @info "Job $job_name has no missing row."
        continue
    end
    @warn "Job $job_name has $nrows missing row(s)."
    times = DateTime.(string.(df[!, 1]), dateformat"yyyy-mm-dd HH:MM:SS")
    sort!(times)
    if isempty(times)
        pairs = DataFrame(first_end_time=DateTime[], last_end_time=DateTime[])
    else
        diffs = diff(times)
        break_idx = findall(d -> d > sampling_frequency, diffs)  # indices i where times[i+1] starts a new run
        start_idx = vcat(1, break_idx .+ 1)
        end_idx = vcat(break_idx, length(times))
        pairs = DataFrame(first_end_time=times[start_idx], last_end_time=times[end_idx])
    end
    @info "Job $job_name missed time ranges:\n$pairs"
end
