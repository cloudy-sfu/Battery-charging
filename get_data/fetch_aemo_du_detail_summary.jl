using HTTP
using ZipFile
using Dates
using CSV
using DataFrames
using SQLite

include(joinpath(pwd(), "sqlite_insertion.jl"))
using .SQLiteInsertion

const DB_PATH = joinpath(pwd(), "get_data", "south_australia.db")
db = SQLite.DB(DB_PATH)
SQLite.execute(db, """
    CREATE TABLE IF NOT EXISTS du_detail_summary (
        duid TEXT NOT NULL,
        region_id TEXT NOT NULL,
        PRIMARY KEY (duid)
    )
""")

url = "https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_04/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23DUDETAILSUMMARY%23FILE01%23202604010000.zip"

resp = HTTP.get(url; readtimeout=2000, retries=3)
reader = ZipFile.Reader(IOBuffer(Vector{UInt8}(resp.body)))
for f in reader.files
    endswith(lowercase(f.name), ".csv") || continue
    # Keep only D (data) rows; columns are accessed positionally below.
    buf = IOBuffer()
    for line in eachline(f; keep=true)
        startswith(line, "D,") && write(buf, line)
    end
    if position(buf) <= 0
        @warn "DUDETAILSUMMARY $(f.name) is empty."
        continue
    end
    df = CSV.read(seekstart(buf), DataFrame; types=String, header=false)
    df = DataFrame(
        duid = df[!, 5],
        end_time = Date.(df[!, 7], dateformat"yyyy/mm/dd HH:MM:SS"),
        region_id = df[!, 10],
    )
    filter!(:end_time => ==(Date("2999-12-31")), df)
    select!(df, Not(:end_time))
    upsert!(db, "du_detail_summary", df, ["duid"])
end
close(reader)
