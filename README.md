# Battery charging
 Battery charging and discharging planning

![](https://shields.io/badge/dependencies-Julia_1.12-purple)

## Install

Create and activate a Julia environment.

## Model definition

This project formulates battery charging and discharging as a mixed-integer linear programming (MILP) problem. Given an electricity market with known demand and known generation from non-battery sources over a planning horizon, a group of batteries is scheduled to charge when the market is in over-supply and to discharge when the market is in shortage. Other generation (such as renewable power generation) sources first meet the demand directly; any surplus is routed to the over-supply grid, where batteries may charge from it. When generation falls short, batteries discharge into the shortage grid to help serve the remaining demand. The objective is to minimize the total unserved electricity demand across the horizon.

```mermaid
%%{init: {'flowchart': {'curve': 'basis'}}}%%
flowchart LR
    ES["Electricity supply<br/>(other sources)"]
    OSM(Over-supply <br/>grid)
    SM(Shortage <br/>grid)
    ED[Electricity<br/>demand]
    BAT[Batteries]

    ES --> OSM
    SM --> ED
    OSM <-.->|"Supply and demand changes"| SM
    OSM -.->|Charge| BAT
    BAT -.->|Discharge| SM

```

### Constants

We have $m$ batteries and intend to serve the electricity market in a time period of $n$ hours.

The electricity demand in each time slot (per hour) is known. Besides the batteries, other sources of power generation in each time slot are known as well. The demand minus all other sources' supply is the amount we need to serve. Denote this amount as $D_{j}, j = 1, ..., n$.

For each battery $i$, we use several arrays of size $1 \times n$ to denote its attributes:

-   The maximum electricity capacity of each battery is $C_{i}$.
-   The charging efficiency is $E_{i}$, the ratio of the amount of electricity added into the battery over the amount of charged electricity.
-   The maximum charging power is $I_{i}$.
-   The maximum discharging power is $O_{i}$.

### Variables

By default, all the variables are non-negative.

Let $t_{j}, \forall j = 1, ..., n$ be unserved amount of electricity in each time slot $j$.

Let $P_{ij}, \forall i = 1, ..., m, \forall j =  1, ..., n$ be discharged amount of electricity of each battery $i$ and each time slot $j$.

Let $H_{ij}, \forall i = 1, ..., m, \forall j =  1, ..., n$ be charged amount of electricity of each battery $i$ and each time slot $j$.

Let $S_{ij}^{c}, \forall i = 1, ..., m, \forall j =  1, ..., n$ be a binary variable to state whether battery $i$ is charging at time slot $j$.

Let $S_{ij}^{d}, \forall i = 1, ..., m, \forall j =  1, ..., n$ be a binary variable to state whether battery $i$ is discharging at time slot $j$.

Let $A_{ij}, \forall i = 1, ..., m, \forall j =  1, ..., n+1$ be the amount of electricity remained in each battery $i$ at the beginning of each time slot $j$.

### The objective function

We penalize the total amount of unserved electricity.

$$
\min{\sum_{j = 1}^{n}t_{j}}
$$

### Constraints

The unserved electricity is lower bounded by the gap between discharging amount and demand. Over-generation is not penalized.

$$
D_{j} - \sum_{i = 1}^{m}P_{ij} \leq t_{j}, \quad \forall j = 1, ..., n
$$

The charging deducts the discharging amount is equal to the difference of remained electricity in the battery between the current and the previous hour.

$$
A_{ij} + E_{i}H_{ij} - P_{ij} = A_{i,j + 1}, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

Specifically, $A_{i,1}, \forall i = 1, ..., m$ is assigned the initial amount of electricity in the battery.

If the battery is not in the charging status, the amount of charging must be 0. If the battery is in the charging status, the amount can be as large as the maximum charging power.

$$
H_{ij} \leq I_{i}S_{ij}^{c}, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

A similar constraint is applied to discharging.

$$
P_{ij} \leq O_{i}S_{ij}^{d}, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

The battery cannot charge and discharge at the same time.

$$
S_{ij}^{c} + S_{ij}^{d} \leq 1, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

If the battery is fully charged, it cannot charge.

$$
A_{ij} \leq C_{i}, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

Similarly, if the battery is empty, it cannot discharge.

$$
P_{ij} \leq A_{ij}, \quad \forall i = 1, ..., m, \quad j = 1, ..., n
$$

If the electricity produced by other sources cannot fulfill the demand, all batteries cannot charge.

$$
\sum_{i = 1}^{m}H_{ij} \leq \max\left( 0, -D_{j} \right), \quad \forall j = 1, ..., n
$$

## Prepare data

### South Australia AEMO Generation

The Australian Energy Market Operator (AEMO) runs the National Electricity Market (NEM), which links the eastern and southern states of Australia through a shared high-voltage transmission grid. AEMO dispatches generators every 5 minutes to match demand at the lowest offered price, and publishes the resulting data, e.g. regional demand, per-unit SCADA generation, and next-day actual generation (non-scheduled dispatchable units).

South Australia is a useful slice of this data, because the region has a high share of wind and rooftop solar, a small number of large grid-scale batteries (such as the Honesdale Power Reserve, Torrens Island BESS, and Lake Bonney BESS), and a handful of gas-fired stations as backup. Each battery appears in AEMO data as one or more dispatchable units (DUIDs) with registered charge or discharge capacity and a storage size in MWh, which map directly onto the model parameters $C_i$, $I_i$, and $O_i$ above. Regional demand minus non-battery generation gives the $D_j$ series this project optimizes against.

The scripts under `get_data/` fetch these feeds and load them into a local SQLite database, so the MILP can be solved on a realistic, recent slice of the South Australian grid.

To collect the data, run the following command in terminal.

```
julia get_data/init_sa_battery.jl
julia get_data/fetch_aemo_dispatched_scada.jl
julia get_data/fetch_aemo_du_detail_summary.jl
julia get_data/fetch_aemo_hist_demand.jl
julia get_data/fetch_aemo_next_day_gen.jl
```

Check the data integrity by run the following command in terminal.

```
julia get_data/south_australia_check_integrity.jl
```

The terminal will output whether the data has missing value and what is the missed time range. Rerun the corresponding script or manually input data into the database to fill missing data. The data integrity check doesn't have a compulsory passing condition, because the program will fill missing values by statistical methods, instead of breaking down.

>   [!note]
>
>   At the moment, re-running `fetch_aemo_dispatched_scada.jl` will check existed data in database and fetch new data incrementally. Other scripts can only fetch all the data and update the whole table.

To create a dataset, run the following command in terminal.

```
julia get_data/south_australia.jl
```

In the web page:

1.   Config specification of the battery group. Save batteries if changed.

![image-20260525172428856](./assets/image-20260525172428856.png)

2.   Select start and end time of electricity load time series (supply and demand) to preview the line plot.

![image-20260525172527059](./assets/image-20260525172527059.png)

3.   Export the dataset containing battery and load to the given file path.

![image-20260525181129899](./assets/image-20260525181129899.png)

![image-20260525181208294](./assets/image-20260525181208294.png)

## Solve

Let the saved dataset file path is `$dataset`.

Assume the file path to save the solution in format of JLD2 is `$solution`; the file path to save the visualization report in format of HTML is `$report` (all can be customized).

To solve the problem and generate the report, run the following command in terminal.

```
julia solve.jl --input_path $dataset --output_path $solution
julia visualization.jl --input_path $solution --output_path $report
```

`solve.jl` has additional arguments:

| Variable    | Data type | Required? | Description                                                  |
| ----------- | --------- | --------- | ------------------------------------------------------------ |
| `--timeout` | Float64   | No        | Maximum time for the solver to solve the optimization problem, in unit of seconds. |

## Results

After solving the model, an HTML report is saved at `$report`.

The report includes the following tabs.

### Summary

Status and value of objective function and variables.

![image-20260526101620397](./assets/image-20260526101620397.png)

### Charging history

Charging and discharging history of each battery. Read segment means discharging; green segment means charging; gray segment means neither charging nor discharging.

The maximum value of Y-axis always the energy capacity of battery.

The X-axis value means the end time of each slot. (The same across all time series plots.)

![Battery 7](./assets/Battery%207.png)

### Power history

The power of inputting or outputting electricity of each battery.

The positive part of Y-axis is output (discharging) power, and the negative part is input (charging) power.

![echarts](./assets/echarts.png)

### Served electricity

The gray bar is the amount of electricity demand. The positive value means other supply resources cannot fulfill the demand of the electricity market; the negative value means redundant electricity is available in the electricity market and batteries owner can use these energy to charge batteries. The stacked bars of batteries are the amount of energy taken or served in each period. 

The following table explains how to compare the height of bars.

| Stacked height of battery bars \_\_\_\_\_\_ the height (absolute value in either direction) of gray bar | Positive gray bar                             | Negative gray bar                              |
| ------------------------------------------------------------ | --------------------------------------------- | ---------------------------------------------- |
| equal to                                                     | All additional demand are served by batteries | All redundant supply are recycled by batteries |
| is shorter than                                              | Outage                                        | Grid waste redundant energy                    |
| is longer than                                               | Batteries waste redundant energy              | (Infeasible)                                   |

![](./assets/served_electricity.png)
