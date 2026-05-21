using ArgParse
using HTTP
using JSON
using Dates

# Command line arguments.
s = ArgParseSettings()
@add_arg_table! s begin
    "--start_time"
        help = "Start time in ISO format (e.g., 2023-01-01T00:00:00)"
        required = true
    "--end_time"
        help = "End time in ISO format (e.g., 2023-01-02T00:00:00)"
        required = true
    "--output_path"
        help = "Path to save the output data."
        required = true
end
parsed_args = parse_args(s)
start_time = parsed_args["start_time"]
end_time = parsed_args["end_time"]
output_path = parsed_args["output_path"]
