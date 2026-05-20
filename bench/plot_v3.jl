using CairoMakie
using Statistics
using Printf

const RESULTS = joinpath(@__DIR__, "..", "results")

function read_csv(path)
    rows = NamedTuple[]
    open(path, "r") do io
        header = split(strip(readline(io)), ',')
        idx = Dict(h => i for (i, h) in enumerate(header))
        for line in eachline(io)
            isempty(strip(line)) && continue
            parts = split(line, ',')
            length(parts) == length(header) || continue
            push!(rows, (
                backend = String(parts[idx["backend"]]),
                total_bytes = parse(Int, parts[idx["total_bytes"]]),
                write_mbps = parse(Float64, parts[idx["write_MBps"]]),
                read_mbps  = parse(Float64, parts[idx["read_MBps"]]),
            ))
        end
    end
    return rows
end

function group_medians(rows)
    bag = Dict{Tuple{String,Int}, Vector{Tuple{Float64,Float64}}}()
    for r in rows
        push!(get!(bag, (r.backend, r.total_bytes), []), (r.write_mbps, r.read_mbps))
    end
    out = Dict{String, Tuple{Vector{Int}, Vector{Float64}, Vector{Float64}}}()
    for ((b, sz), vs) in bag
        szs, ws, rs = get!(out, b, (Int[], Float64[], Float64[]))
        push!(szs, sz); push!(ws, median(first.(vs))); push!(rs, median(last.(vs)))
    end
    for k in keys(out)
        szs, ws, rs = out[k]
        perm = sortperm(szs)
        out[k] = (szs[perm], ws[perm], rs[perm])
    end
    return out
end

const STYLE = Dict(
    "zarrjl_optimized_v3" => (label = "Zarr.jl v3 (optimized)", color = :crimson, marker = :circle),
    "zarrsjl"             => (label = "Zarrs.jl (v3 native)",   color = :steelblue, marker = :rect),
)
const ORDER = ["zarrjl_optimized_v3", "zarrsjl"]

function bytes_ticks(maxbytes)
    vals = [16, 64, 256, 1024, 4096] .* 1_048_576  # MiB → bytes
    labs = ["16 MiB", "64 MiB", "256 MiB", "1 GiB", "4 GiB"]
    keep = vals .<= maxbytes * 1.1
    return (vals[keep], labs[keep])
end

function plot_v3(rows, outpath)
    medians = group_medians(rows)
    maxbytes = maximum(maximum(v[1]) for v in values(medians))
    xticks = bytes_ticks(maxbytes)

    fig = Figure(size = (1100, 460))

    axw = Axis(fig[1, 1];
        title = "Write throughput",
        xlabel = "Array size",
        ylabel = "MiB/s",
        xscale = log10,
        yscale = log10,
        xticks = xticks,
    )
    axr = Axis(fig[1, 2];
        title = "Read throughput",
        xlabel = "Array size",
        ylabel = "MiB/s",
        xscale = log10,
        yscale = log10,
        xticks = xticks,
    )

    for b in ORDER
        haskey(medians, b) || continue
        szs, ws, rs = medians[b]
        st = STYLE[b]
        lines!(axw, szs, ws; color = st.color, linewidth = 2.5, label = st.label)
        scatter!(axw, szs, ws; color = st.color, marker = st.marker, markersize = 10)
        lines!(axr, szs, rs; color = st.color, linewidth = 2.5, label = st.label)
        scatter!(axr, szs, rs; color = st.color, marker = st.marker, markersize = 10)
    end

    Legend(fig[2, 1:2], axw; orientation = :horizontal, framevisible = false)
    Label(fig[0, 1:2],
        "Zarr v3 uncompressed, one full chunk per timestep — sequential write/read";
        fontsize = 16, font = :bold)

    save(outpath, fig)
    @info "Wrote $outpath"
    return outpath
end

if abspath(PROGRAM_FILE) == @__FILE__
    csv = joinpath(RESULTS, "v3_optimized_vs_zarrs_full.csv")
    out = joinpath(RESULTS, "v3_throughput_vs_size.png")
    rows = read_csv(csv)
    plot_v3(rows, out)
end
