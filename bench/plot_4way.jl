# plot_4way.jl — render the 4-way comparison (baseline / propA / propB / Zarrs)
# from results/sequential_4way.csv. Single-threaded, uncompressed.

using CairoMakie
using Statistics
using Printf

const RESULTS = joinpath(@__DIR__, "..", "results")

struct Row
    cols::Dict{String,String}
end
Base.getindex(r::Row, k::AbstractString) = r.cols[k]

function read_csv(path::AbstractString)
    rows = Row[]
    open(path, "r") do io
        header = split(strip(readline(io)), ',')
        for line in eachline(io)
            isempty(strip(line)) && continue
            parts = split(line, ',')
            length(parts) == length(header) || continue
            push!(rows, Row(Dict(zip(String.(header), String.(parts)))))
        end
    end
    return rows
end

const COLOR = Dict(
    "mmap"                 => :black,
    "raw"                  => :gray60,
    "zarrjl_baseline_v2"   => :tomato,
    "zarrjl_baseline_v3"   => :firebrick4,
    "zarrjl_propA_v2"      => :seagreen3,
    "zarrjl_propA_v3"      => :darkgreen,
    "zarrjl_propB_v2"      => :tan2,
    "zarrjl_propB_v3"      => :saddlebrown,
    "zarrsjl"              => :steelblue,
)
const LABEL = Dict(
    "mmap"                 => "Mmap (theoretical)",
    "raw"                  => "Raw write/read",
    "zarrjl_baseline_v2"   => "Zarr.jl baseline (V2)",
    "zarrjl_baseline_v3"   => "Zarr.jl baseline (V3)",
    "zarrjl_propA_v2"      => "Zarr.jl + Prop A (V2)",
    "zarrjl_propA_v3"      => "Zarr.jl + Prop A (V3)",
    "zarrjl_propB_v2"      => "Zarr.jl + Prop B (V2)",
    "zarrjl_propB_v3"      => "Zarr.jl + Prop B (V3)",
    "zarrsjl"              => "Zarrs.jl (V3 native)",
)

const ORDER = ["mmap", "raw",
               "zarrjl_baseline_v2", "zarrjl_baseline_v3",
               "zarrjl_propA_v2", "zarrjl_propA_v3",
               "zarrjl_propB_v2", "zarrjl_propB_v3",
               "zarrsjl"]

function aggregate(rows, metric)
    bag = Dict{Tuple{String,Int}, Vector{Float64}}()
    for r in rows
        key = (r["backend"], parse(Int, r["total_bytes"]))
        push!(get!(bag, key, Float64[]), parse(Float64, r[metric]))
    end
    out = Dict{String, Tuple{Vector{Int}, Vector{Float64}}}()
    for ((b, sz), vs) in bag
        t = get!(out, b, (Int[], Float64[]))
        push!(t[1], sz); push!(t[2], median(vs))
    end
    for (k, (xs, ys)) in out
        perm = sortperm(xs)
        out[k] = (xs[perm], ys[perm])
    end
    return out
end

function _fmt_bytes(n)
    n = Float64(n)
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    i = 1
    while n >= 1024 && i < length(units)
        n /= 1024
        i += 1
    end
    return @sprintf("%.0f %s", n, units[i])
end

function plot_4way(rows, outpath)
    fig = Figure(size=(1200, 520))

    for (col_idx, (metric, title)) in enumerate([("write_MBps", "Sequential write"),
                                                  ("read_MBps",  "Sequential read")])
        ax = Axis(fig[1, col_idx];
            title = title,
            xlabel = "Total data size",
            ylabel = "MiB / s",
            xscale = log10,
            yscale = log10,
            xminorticksvisible = true,
            yminorticksvisible = true,
        )
        agg = aggregate(rows, metric)
        for backend in ORDER
            haskey(agg, backend) || continue
            xs, ys = agg[backend]
            isempty(xs) && continue
            color = COLOR[backend]
            label = LABEL[backend]
            # Make the four Zarr.jl/Zarrs.jl lines bolder; the mmap/raw
            # baselines thinner since they're context.
            lw = startswith(backend, "zarr") ? 2.5 : 1.5
            lines!(ax, xs, ys; color=color, linewidth=lw, label=label)
            scatter!(ax, xs, ys; color=color, markersize=8)
        end
        ax.xtickformat = (vals) -> [_fmt_bytes(v) for v in vals]
        if col_idx == 2
            axislegend(ax; position=:rb, labelsize=10, framevisible=true, rowgap=2)
        end
    end

    Label(fig[0, :], "Zarr.jl vs Zarrs.jl: four-way comparison (uncompressed, single-threaded)";
          fontsize=15, halign=:center)
    save(outpath, fig)
    @info "wrote $outpath"
end

function main()
    csv = joinpath(RESULTS, "sequential_4way.csv")
    isfile(csv) || error("missing $csv — run bench/bench_4way.jl first")
    rows = read_csv(csv)
    plot_4way(rows, joinpath(RESULTS, "throughput_4way.png"))
end

main()
