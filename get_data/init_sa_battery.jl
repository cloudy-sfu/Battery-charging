#=
init_sa_battery.jl

Create / refresh the `batteries` table in `south_australia.db` and seed it
with publicly known grid-scale battery storage projects located in the
South Australian (SA1) NEM region.

Columns map 1:1 to the inputs collected by the "Batteries group" section
of `config_data.html`:

    capacity    REAL     -- energy capacity (MWh)
    level       REAL     -- initial state of charge, 0..1
    c_power     REAL     -- max charging power (MW)
    d_power     REAL     -- max discharging power (MW)
    efficiency  REAL     -- round-trip charging efficiency, 0..1

The table is always read and written as a whole, so no row identity column
is kept.

Sources (public): AEMO Generation Information, project operator press
releases and Wikipedia entries for each site. Values reflect the
nameplate / commissioned configuration at the time of writing; edit
freely in the companion Genie editor before exporting a dataset.
=#

using SQLite
using DataFrames

const DB_PATH = joinpath(pwd(), "get_data", "south_australia.db")

# energy MWh, power MW (max in == max out assumed), efficiency
const SA_BATTERIES = [
    # Hornsdale Power Reserve (Neoen / Tesla), Jamestown SA
    (194.0, 150.0, 0.88),
    # Torrens Island BESS (AGL), Adelaide
    (250.0, 250.0, 0.87),
    # Dalrymple / ESCRI BESS (AGL / ElectraNet), Yorke Peninsula
    (  8.0,  30.0, 0.85),
    # Lake Bonney BESS (Infigen / Iberdrola), south-east SA
    ( 52.0,  25.0, 0.86),
    # Tailem Bend BESS (Vena Energy), co-located with Tailem Bend Solar
    (  5.0,   5.0, 0.85),
    # Bungama BESS (AGL), Port Pirie -- commissioning
    (500.0, 250.0, 0.87),
    # Blyth Battery (Neoen), Mid North SA -- under construction
    (800.0, 200.0, 0.88),
]

db = SQLite.DB(DB_PATH)
SQLite.DBInterface.execute(db, "DROP TABLE IF EXISTS batteries")
SQLite.DBInterface.execute(db, """
    CREATE TABLE batteries (
        capacity    REAL NOT NULL CHECK(capacity   > 0),
        level       REAL NOT NULL CHECK(level     >= 0 AND level      <= 1),
        c_power     REAL NOT NULL CHECK(c_power     > 0),
        d_power     REAL NOT NULL CHECK(d_power     > 0),
        efficiency  REAL NOT NULL CHECK(efficiency >  0 AND efficiency <= 1)
    )
""")
for (mwh, mw, eff) in SA_BATTERIES
    SQLite.DBInterface.execute(db, """
        INSERT INTO batteries (capacity, level, c_power, d_power, efficiency)
        VALUES (?, ?, ?, ?, ?)
    """, (mwh, 0.5, mw, mw, eff))
end
df = DataFrame(SQLite.DBInterface.execute(
    db, "SELECT * FROM batteries"))
show(stdout, df; allcols = true, allrows = true)
