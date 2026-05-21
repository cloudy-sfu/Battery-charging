using HTTP
using ZipFile
using SQLite
using Dates
using Gumbo  # like BeautifulSoup4
using CSV
using DataFrames

include(joinpath(pwd(), "sqlite_insertion.jl"))
using .SQLiteInsertion

const DOMAIN      = "https://nemweb.com.au"
const ARCHIVE_URL = DOMAIN * "/Reports/ARCHIVE/HistDemand/"
const CURRENT_URL = DOMAIN * "/Reports/CURRENT/HistDemand/"
const DB_PATH = joinpath(pwd(), "get_data", "south_australia.db")

# HTML directory listing
function list_links(url::AbstractString)
    resp = HTTP.get(url; readtimeout=60, retries=3)
    doc = parsehtml(String(resp.body))

    # Locate XPath /html/body/pre
    body = first(e for e in doc.root.children if e isa HTMLElement && tag(e) == :body)
    pre  = first(e for e in body.children     if e isa HTMLElement && tag(e) == :pre)

    hrefs = String[]
    walk(node) = begin
        if node isa HTMLElement
            if tag(node) == :a && haskey(attrs(node), "href") &&
               endswith(lowercase(attrs(node)["href"]), ".zip")
                push!(hrefs, attrs(node)["href"])
            end
            for c in node.children
                walk(c)
            end
        end
    end
    walk(pre)
    return hrefs
end

# --- CSV parsing ---
# AEMO HISTDEMAND CSVs are heterogeneous (C/I/D/... record types per row).
# Pipeline: keep first "I" line (header) and all "D" lines -> parse as
# DataFrame in one shot -> vectorized datetime = SETTLEMENTDATE + (PERIODID-1)*30min
# -> select (region_id, datetime, load) -> filter region -> write to DB.
function parse_csv_bytes(bytes::Vector{UInt8}, source::AbstractString)
    # Keep only D (data) rows; columns are accessed positionally below.
    buf = IOBuffer()
    for line in eachline(IOBuffer(bytes); keep=true)
        startswith(line, "D,") && write(buf, line)
    end
    if position(buf) <= 0
        @warn "Data of $source is empty."
        return nothing
    end

    df = CSV.read(seekstart(buf), DataFrame; types=String, header=false)

    # AEMO HISTDEMAND columns (positional, since header has a duplicate "DEMAND"):
    #   1=record type, 2="DEMAND", 3="HISTORIC", 4=version,
    #   5=REGIONID, 6=SETTLEMENTDATE, 7=PERIODID, 8=DEMAND (numeric)
    dates   = Date.(df[!, 6], dateformat"yyyy/mm/dd HH:MM:SS")
    periods = parse.(Int, df[!, 7])
    @info "CSV file of $source is processed."

    return DataFrame(
        region_id = df[!, 5],
        end_time = Dates.format.(DateTime.(dates) .+ Minute.(periods .* 30),
                                  dateformat"yyyy-mm-dd HH:MM:SS"),
        load      = parse.(Int, df[!, 8]),
    )
end

# --- ZIP processing (CSV-only zip; used for CURRENT daily zips and for
# inner zips extracted from monthly ARCHIVE zips) ---
function process_zip_bytes!(db::SQLite.DB, bytes::Vector{UInt8})
    reader = ZipFile.Reader(IOBuffer(bytes))
    for f in reader.files
        endswith(lowercase(f.name), ".csv") || continue
        df = parse_csv_bytes(read(f), f.name)
        if df !== nothing
            upsert!(db, "dispatched_scada", df, ["duid", "end_time"])
        end
    end
    close(reader)
end

# Monthly ARCHIVE zips wrap daily CSV zips; unwrap one level then delegate.
function process_archive_zip_bytes!(db::SQLite.DB, bytes::Vector{UInt8})
    reader = ZipFile.Reader(IOBuffer(bytes))
    for f in reader.files
        endswith(lowercase(f.name), ".zip") || continue
        try
            process_zip_bytes!(db, read(f))
        catch e
            @warn "Skipping broken file $(f.name) Reason: $e"
        end
    end
    close(reader)
end

# Init DB
db = SQLite.DB(DB_PATH)
SQLite.execute(db, """
    CREATE TABLE IF NOT EXISTS historical_demand (
        region_id TEXT NOT NULL,
        end_time  TEXT NOT NULL,
        load      INTEGER NOT NULL,
        PRIMARY KEY (region_id, end_time)
    )
""")
for href in list_links(ARCHIVE_URL)
    url = DOMAIN * href
    try
        resp = HTTP.get(url; readtimeout=2000, retries=3)
        process_archive_zip_bytes!(db, Vector{UInt8}(resp.body))
    catch e
        @warn "Cannot parse $url Reason: $e"
    end
    sleep(0.3)
end
for href in list_links(CURRENT_URL)
    url = DOMAIN * href
    try
        resp = HTTP.get(url; readtimeout=2000, retries=3)
        process_zip_bytes!(db, Vector{UInt8}(resp.body))
    catch e
        @warn "Cannot parse $url Reason: $e"
    end
    sleep(0.3)
end
