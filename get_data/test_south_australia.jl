include(joinpath(pwd(), "get_data", "south_australia.jl"))

batteries = load_batteries()
println(batteries)
load, _ = fetch_supply_demand("2026-05-13 18:00", "2026-05-16 18:00")
println(load)
