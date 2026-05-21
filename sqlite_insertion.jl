module SQLiteInsertion

using SQLite
using DataFrames

export upsert!, do_nothing_if_not_exists!

# Default row chunk size. SQLite's SQLITE_MAX_VARIABLE_NUMBER is 999 on legacy
# builds and 32766 on modern (>=3.32) builds; 300 rows stays safe for tables
# of up to ~3 columns on legacy SQLite. Bump for wider tables or modern SQLite.
const DEFAULT_CHUNK_SIZE = 300

_row_placeholder(ncols::Integer) =
    string("(", join(Iterators.repeated("?", ncols), ","), ")")

# Insert `df` into `table` in row-chunks; `tail` is appended to each statement
# (e.g. an ON CONFLICT clause).
function _chunked_insert!(db::SQLite.DB, table::AbstractString, df::DataFrame,
                          cols::AbstractVector{<:AbstractString},
                          tail::AbstractString, chunk_size::Integer)
    n = nrow(df)
    n == 0 && return 0
    ncols = length(cols)
    ncols > 0 || throw(ArgumentError("`cols` must be non-empty"))
    chunk_size >= 1 || throw(ArgumentError("`chunk_size` must be >= 1"))

    colvecs = [df[!, c] for c in cols]
    row_ph = _row_placeholder(ncols)
    col_list = join(cols, ",")

    for lo in 1:chunk_size:n
        hi = min(lo + chunk_size - 1, n)
        k = hi - lo + 1
        sql = string("INSERT INTO ", table, " (", col_list, ") VALUES ",
                     join(Iterators.repeated(row_ph, k), ","), tail)
        params = Vector{Any}(undef, ncols * k)
        @inbounds for j in 1:k, c in 1:ncols
            params[(j - 1) * ncols + c] = colvecs[c][lo + j - 1]
        end
        SQLite.DBInterface.execute(db, sql, params)
    end
    return n
end

_validate_unique(cols, unique_cols) =
    for u in unique_cols
        u in cols || throw(ArgumentError("unique col $(repr(u)) not in `cols`"))
    end

"""
    upsert!(db, table, df, unique_cols; cols=names(df), chunk_size=300)

Bulk `INSERT ... ON CONFLICT(unique_cols) DO UPDATE SET ...`: insert new rows
and overwrite existing rows that collide on `unique_cols`. Non-unique columns
in `cols` are updated from the incoming row (`excluded`).

`unique_cols` must match a `UNIQUE` or `PRIMARY KEY` constraint on `table`.
"""
function upsert!(db::SQLite.DB, table::AbstractString, df::DataFrame,
                 unique_cols::AbstractVector{<:AbstractString};
                 cols::AbstractVector{<:AbstractString} = names(df),
                 chunk_size::Integer = DEFAULT_CHUNK_SIZE)
    _validate_unique(cols, unique_cols)
    update_cols = [c for c in cols if !(c in unique_cols)]
    tail = if isempty(update_cols)
        string(" ON CONFLICT(", join(unique_cols, ","), ") DO NOTHING")
    else
        set_clause = join((string(c, "=excluded.", c) for c in update_cols), ",")
        string(" ON CONFLICT(", join(unique_cols, ","), ") DO UPDATE SET ", set_clause)
    end
    return _chunked_insert!(db, table, df, cols, tail, chunk_size)
end

"""
    do_nothing_if_not_exists!(db, table, df, unique_cols; cols=names(df), chunk_size=300)

Bulk `INSERT ... ON CONFLICT(unique_cols) DO NOTHING`: insert only rows whose
`unique_cols` do not already exist; existing rows are untouched.
"""
function do_nothing_if_not_exists!(db::SQLite.DB, table::AbstractString,
                                   df::DataFrame,
                                   unique_cols::AbstractVector{<:AbstractString};
                                   cols::AbstractVector{<:AbstractString} = names(df),
                                   chunk_size::Integer = DEFAULT_CHUNK_SIZE)
    _validate_unique(cols, unique_cols)
    tail = string(" ON CONFLICT(", join(unique_cols, ","), ") DO NOTHING")
    return _chunked_insert!(db, table, df, cols, tail, chunk_size)
end

end # module
