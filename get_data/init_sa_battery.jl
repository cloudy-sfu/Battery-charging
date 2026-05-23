#=
init_sa_battery.jl

Create / refresh the `batteries` table in `south_australia.db` and seed it
with publicly known grid-scale battery storage projects located in the
South Australian (SA1) NEM region.

Columns map 1:1 to the inputs collected by the "Batteries group" section
of `index.html`:

    name        TEXT     -- project name (primary key)
    capacity    REAL     -- energy capacity (MWh)
    level       REAL     -- initial state of charge, 0..1
    c_duration  REAL     -- charging duration (h) = capacity / max input power
    d_duration  REAL     -- discharging duration (h) = capacity / max output power
    efficiency  REAL     -- round-trip charging efficiency, 0..1

Sources (public): AEMO Generation Information, project operator press
releases and Wikipedia entries for each site. Values reflect the
nameplate / commissioned configuration at the time of writing; edit
freely in the companion Genie editor before exporting a dataset.
=#

using SQLite
using DataFrames

const DB_PATH = joinpath(pwd(), "get_data", "south_australia.db")

# name, energy MWh, power MW (max in == max out assumed), efficiency
const SA_BATTERIES = [
    # Hornsdale Power Reserve (Neoen / Tesla), Jamestown SA
    ("Hornsdale Power Reserve", 194.0, 150.0, 0.88),
    # Torrens Island BESS (AGL), Adelaide
    ("Torrens Island BESS",     250.0, 250.0, 0.87),
    # Dalrymple / ESCRI BESS (AGL / ElectraNet), Yorke Peninsula
    ("Dalrymple ESCRI BESS",      8.0,  30.0, 0.85),
    # Lake Bonney BESS (Infigen / Iberdrola), south-east SA
    ("Lake Bonney BESS",         52.0,  25.0, 0.86),
    # Tailem Bend BESS (Vena Energy), co-located with Tailem Bend Solar
    ("Tailem Bend BESS",          5.0,   5.0, 0.85),
    # Bungama BESS (AGL), Port Pirie -- commissioning
    ("Bungama BESS",            500.0, 250.0, 0.87),
    # Blyth Battery (Neoen), Mid North SA -- under construction
    ("Blyth Battery",           800.0, 200.0, 0.88),
]

db = SQLite.DB(DB_PATH)
SQLite.DBInterface.execute(db, """
    CREATE TABLE IF NOT EXISTS batteries (
        name        TEXT PRIMARY KEY,
        capacity    REAL NOT NULL CHECK(capacity   > 0),
        level       REAL NOT NULL CHECK(level     >= 0 AND level      <= 1),
        c_duration  REAL NOT NULL CHECK(c_duration > 0),
        d_duration  REAL NOT NULL CHECK(d_duration > 0),
        efficiency  REAL NOT NULL CHECK(efficiency >  0 AND efficiency <= 1)
    )
""")
for (name, mwh, mw, eff) in SA_BATTERIES
    SQLite.DBInterface.execute(db, """
        INSERT INTO batteries (name, capacity, level, c_duration, d_duration, efficiency)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            capacity   = excluded.capacity,
            c_duration = excluded.c_duration,
            d_duration = excluded.d_duration,
            efficiency = excluded.efficiency
    """, (name, mwh, 0.5, mwh / mw, mwh / mw, eff))
end
df = DataFrame(SQLite.DBInterface.execute(
    db, "SELECT * FROM batteries ORDER BY name"))
show(stdout, df; allcols = true, allrows = true)
