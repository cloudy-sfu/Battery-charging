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
const ARCHIVE_URL = DOMAIN * "/Reports/ARCHIVE/Dispatch_SCADA/" 
# https://nemweb.com.au/Reports/CURRENT/Dispatch_SCADA/
const CURRENT_URL = DOMAIN * "/Reports/CURRENT/Dispatch_SCADA/"
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
    # D,METER_DATA,GEN_DUID,1,INTERVAL_DATETIME,DUID,MWH_READING,LASTCHANGED
    @info "CSV file of $source is processed."

    return DataFrame(
        duid = df[!, 6],
        end_time = Dates.format.(DateTime.(df[!, 5], dateformat"yyyy/mm/dd HH:MM:SS"),
                                 dateformat"yyyy-mm-dd HH:MM:SS"),
        load = parse.(Float64, df[!, 7]),
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
    CREATE TABLE IF NOT EXISTS dispatched_scada (
        duid TEXT NOT NULL,
        end_time  TEXT NOT NULL,
        load      REAL NOT NULL,
        PRIMARY KEY (duid, end_time)
    )
""")
SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_dispatched_scada_duid_endtime ON dispatched_scada(duid, end_time)")
SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_dispatched_scada_endtime ON dispatched_scada(end_time)")
const COMPLETED_DATES_SQL = read(joinpath(
    pwd(), "get_data", "sqls_south_australia", "get_dispatched_scada_completed_date.sql"), 
    String)
completed_dates = Set(
    DBInterface.execute(db, COMPLETED_DATES_SQL) |> DataFrame |> df -> df.date_)
for href in list_links(ARCHIVE_URL)
    match_ = match(r"PUBLIC_DISPATCHSCADA_(\d+)", href)
    if (match_ !== nothing)
        date_1 = Date(match_.captures[1], dateformat"yyyymmdd")
        date_2 = Dates.format(date_1, dateformat"yyyy-mm-dd")
        if (date_2 in completed_dates)
            continue
        end
        url = DOMAIN * href
        try
            resp = HTTP.get(url; readtimeout=2000, retries=3)
            process_archive_zip_bytes!(db, Vector{UInt8}(resp.body))
        catch e
            @warn "Cannot parse $url Reason: $e"
        end
        sleep(0.3)
    else
        @warn "ZIP file URL $href is invalid."
    end
end
const COMPLETED_DATES_RECENT_SQL = read(joinpath(
    pwd(), "get_data", "sqls_south_australia", "get_dispatched_scada_completed_date_recent.sql"), 
    String)
completed_datetime = Set(
    DBInterface.execute(db, COMPLETED_DATES_RECENT_SQL) |> DataFrame |> df -> df.end_time)
for href in list_links(CURRENT_URL)
    match_ = match(r"PUBLIC_DISPATCHSCADA_(\d+)", href)
    if (match_ !== nothing)
        date_1 = DateTime(match_.captures[1], dateformat"yyyymmddHHMM")
        date_2 = Dates.format(date_1, dateformat"yyyy-mm-dd HH:MM:SS")
        if (date_2 in completed_datetime)
            continue
        end
        url = DOMAIN * href
        try
            resp = HTTP.get(url; readtimeout=2000, retries=3)
            process_zip_bytes!(db, Vector{UInt8}(resp.body))
        catch e
            @warn "Cannot parse $url Reason: $e"
        end
        sleep(0.3)
    else
        @warn "ZIP file URL $href is invalid."
    end
end
