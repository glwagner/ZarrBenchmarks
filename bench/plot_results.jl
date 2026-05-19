# plot_results.jl
# ------------------------------------------------------------
# Reads the CSVs in results/ and writes a set of figures.
#
# Inputs:
#   results/sequential.csv  (from bench_sequential.jl)
#   results/threads.csv     (from bench_threads.jl)
#
# Outputs (PNG):
#   results/throughput_vs_size.png
#   results/throughput_vs_threads.png

using CairoMakie
using Statistics
using Printf

const RESULTS = joinpath(@__DIR__, "..", "results")

# ---------------------------------------------------------------------------
# Minimal CSV reader (avoids a CSV.jl/DataFrames dependency)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Plot helpers
# ---------------------------------------------------------------------------

const BACKEND_COLORS = Dict(
    "mmap"    => :black,
    "raw"     => :gray50,
    "zarrjl"  => :tomato,
    "zarrsjl" => :steelblue,
)

const BACKEND_LABELS = Dict(
    "mmap"    => "Mmap (theoretical)",
    "raw"     => "Raw write/read",
    "zarrjl"  => "Zarr.jl",
    "zarrsjl" => "Zarrs.jl",
)

# ---------------------------------------------------------------------------
# Throughput vs data size
# ---------------------------------------------------------------------------

function plot_throughput_vs_size(rows, outpath; codecs=["none"])
    fig = Figure(size=(1100, 480))

    # Group by (backend, codec); plot one line per group with x = total_bytes,
    # y = median MB/s across repeats.
    function aggregate(rows, metric_col)
        # Map (backend, codec, total_bytes) -> [values]
        bag = Dict{Tuple{String,String,Int}, Vector{Float64}}()
        for r in rows
            key = (r["backend"], r["codec"], parse(Int, r["total_bytes"]))
            push!(get!(bag, key, Float64[]), parse(Float64, r[metric_col]))
        end
        # Then reshape to backend,codec -> sorted vectors
        out = Dict{Tuple{String,String}, Tuple{Vector{Int}, Vector{Float64}}}()
        for ((b,c,sz), vs) in bag
            t = get!(out, (b,c), (Int[], Float64[]))
            push!(t[1], sz)
            push!(t[2], median(vs))
        end
        # sort by size
        for (k, (xs, ys)) in out
            perm = sortperm(xs)
            out[k] = (xs[perm], ys[perm])
        end
        return out
    end

    for (col_idx, (metric, title)) in enumerate([("write_MBps", "Write throughput"),
                                                  ("read_MBps",  "Read throughput")])
        agg = aggregate(rows, metric)
        ax = Axis(fig[1, col_idx];
            title = title,
            xlabel = "Total data size",
            ylabel = "MiB / s",
            xscale = log10,
            yscale = log10,
            xminorticksvisible = true,
            yminorticksvisible = true,
        )

        backends_seen = String[]
        for codec in codecs
            for backend in ("mmap", "raw", "zarrjl", "zarrsjl")
                key = (backend, codec)
                haskey(agg, key) || continue
                xs, ys = agg[key]
                isempty(xs) && continue
                color = BACKEND_COLORS[backend]
                label = "$(BACKEND_LABELS[backend]) ($codec)"
                lines!(ax, xs, ys; color=color,
                       linewidth = (codec == "none" ? 2.5 : 1.5),
                       linestyle = (codec == "none" ? :solid : :dash),
                       label=label)
                scatter!(ax, xs, ys; color=color, markersize=8)
                push!(backends_seen, label)
            end
        end

        # Use byte-suffix x-tick formatter
        ax.xtickformat = (vals) -> [_fmt_bytes(v) for v in vals]

        if col_idx == 2
            axislegend(ax; position=:rb, labelsize=9, framevisible=true)
        end
    end

    Label(fig[0, :], "Throughput vs total data size  (single-chunk-per-timestep, 4D append-along-trailing)";
          fontsize=15, halign=:center)
    save(outpath, fig)
    @info "wrote $outpath"
end

_fmt_bytes(n) = begin
    n = Float64(n)
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    i = 1
    while n >= 1024 && i < length(units)
        n /= 1024
        i += 1
    end
    @sprintf("%.0f %s", n, units[i])
end

# ---------------------------------------------------------------------------
# Throughput vs threads
# ---------------------------------------------------------------------------

function plot_throughput_vs_threads(rows, outpath)
    # x = rayon_threads, y = MiB/s, lines per (backend, codec).
    fig = Figure(size=(1100, 520))

    function group_by_backend_codec(rows, metric)
        out = Dict{Tuple{String,String}, Tuple{Vector{Int}, Vector{Float64}}}()
        bag = Dict{Tuple{String,String,Int}, Vector{Float64}}()
        for r in rows
            nth = r["rayon_threads"]
            isempty(nth) && continue
            key = (r["backend"], r["codec"], parse(Int, nth))
            push!(get!(bag, key, Float64[]), parse(Float64, r[metric]))
        end
        for ((b, c, nth), vs) in bag
            t = get!(out, (b, c), (Int[], Float64[]))
            push!(t[1], nth)
            push!(t[2], median(vs))
        end
        for (k, (xs, ys)) in out
            perm = sortperm(xs)
            out[k] = (xs[perm], ys[perm])
        end
        return out
    end

    for (col_idx, (metric, title)) in enumerate([("write_MBps", "Write throughput"),
                                                  ("read_MBps",  "Read throughput")])
        ax = Axis(fig[1, col_idx];
            title = title,
            xlabel = "Thread count",
            ylabel = "MiB / s",
            xticks = (Int[], String[]),
        )
        agg = group_by_backend_codec(rows, metric)
        all_x = Int[]
        for codec in ("none", "zstd", "blosc", "zlib")
            for backend in ("zarrjl", "zarrsjl")
                haskey(agg, (backend, codec)) || continue
                xs, ys = agg[(backend, codec)]
                isempty(xs) && continue
                color = BACKEND_COLORS[backend]
                ls = codec == "none" ? :solid : :dash
                lines!(ax, xs, ys; color=color, linewidth=2.5, linestyle=ls,
                       label="$(BACKEND_LABELS[backend]) ($codec)")
                scatter!(ax, xs, ys; color=color, markersize=8)
                append!(all_x, xs)
            end
        end
        if !isempty(all_x)
            uniq = sort(unique(all_x))
            ax.xticks = (uniq, string.(uniq))
        end
        if col_idx == 2
            axislegend(ax; position=:rb, labelsize=9, framevisible=true)
        end
    end

    Label(fig[0, :], "Throughput vs thread count  (solid=uncompressed, dashed=zstd-3)";
          fontsize=15, halign=:center)
    save(outpath, fig)
    @info "wrote $outpath"
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main()
    seq_csv = joinpath(RESULTS, "sequential.csv")
    if isfile(seq_csv)
        rows = read_csv(seq_csv)
        codecs = sort(unique(r["codec"] for r in rows))
        plot_throughput_vs_size(rows, joinpath(RESULTS, "throughput_vs_size.png"); codecs=codecs)
    else
        @warn "no sequential.csv — skipping size plot"
    end

    th_csv = joinpath(RESULTS, "threads.csv")
    if isfile(th_csv)
        rows = read_csv(th_csv)
        plot_throughput_vs_threads(rows, joinpath(RESULTS, "throughput_vs_threads.png"))
    else
        @warn "no threads.csv — skipping threads plot"
    end
end

main()
