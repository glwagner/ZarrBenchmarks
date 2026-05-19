# bench_sequential.jl
# ------------------------------------------------------------
# Sequential time-series benchmark:
#   * Write Nt timesteps of a 3D (Nx, Ny, Nz) Float32 field to a 4D array
#     (Nx, Ny, Nz, Nt) along the trailing axis.
#   * Re-open and read the timesteps back sequentially.
#   * Repeat for a sweep of field sizes and codecs.
#
# Methodology:
#   * One warm-up run per (backend, size, codec) configuration is discarded.
#   * Each timed run measures `Base.@elapsed` for the whole write loop, then
#     fsyncs all chunk files before stopping the clock.  Reads similarly time
#     the full sequential pass.
#   * Buffers are pre-allocated outside the timed window.
#   * Data is generated outside the timed window where possible (we do a
#     small in-place rewrite for each timestep to keep the compressor honest
#     when compression is enabled).
#   * On-disk size is captured per run.
#   * Throughput = total_bytes / wall_time.
#
# Usage:
#   julia --project bench/bench_sequential.jl [out_csv]
#
# Environment variables:
#   ZS_SIZES   — semicolon-separated list of "Nx,Ny,Nz,Nt" tuples (override default sweep)
#   ZS_CODECS  — comma-separated list of codecs from {none, zstd, blosc, zlib}
#   ZS_REPEATS — number of timed repeats per config (default 3)
#   ZS_BACKENDS — comma-separated subset of {mmap, raw, zarrjl, zarrsjl}

include(joinpath(@__DIR__, "common.jl"))
using .ZarrBenchCommon
include(joinpath(@__DIR__, "backends.jl"))
using .ZarrBenchBackends

using Printf
using Statistics

# ---------------------------------------------------------------------------
# Run config
# ---------------------------------------------------------------------------

const DEFAULT_SIZES = [
    # (Nx, Ny, Nz, Nt) -- total bytes = 4 * Nx*Ny*Nz*Nt
    (64,  64,  16,  50),   #   12.5 MiB
    (128, 128, 16,  50),   #   50   MiB
    (128, 128, 32,  50),   #  100   MiB
    (256, 256, 16,  50),   #  200   MiB
    (256, 256, 32,  50),   #  400   MiB
    (256, 256, 64,  50),   #  800   MiB
    (512, 512, 32,  50),   #  1.5  GiB
    (512, 512, 64,  20),   #  1.25 GiB (fewer steps -> larger frames)
    (512, 512, 64,  50),   #  3.1  GiB
]

function parse_sizes(s)
    s === nothing && return DEFAULT_SIZES
    [Tuple(parse.(Int, split(t, ','))) for t in split(s, ';') if !isempty(t)]
end

function parse_csv_list(s, default)
    s === nothing && return default
    return String.(split(s, ','))
end

const SIZES    = parse_sizes(get(ENV, "ZS_SIZES", nothing))
const CODECS   = parse_csv_list(get(ENV, "ZS_CODECS", nothing), ["none"])
const REPEATS  = parse(Int, get(ENV, "ZS_REPEATS", "3"))
const BACKENDS = parse_csv_list(get(ENV, "ZS_BACKENDS", nothing),
                                ["mmap", "raw", "zarrjl", "zarrsjl"])

const OUT_CSV = length(ARGS) >= 1 ? ARGS[1] :
    joinpath(@__DIR__, "..", "results", "sequential.csv")
const TMP_ROOT = joinpath(tempdir(), "zarr_benchmarks_seq")
isdir(TMP_ROOT) && rm(TMP_ROOT; recursive=true, force=true)
mkpath(TMP_ROOT)
mkpath(dirname(OUT_CSV))

# ---------------------------------------------------------------------------
# Codec → level mapping
# ---------------------------------------------------------------------------
codec_level(codec::AbstractString) =
    codec == "none"  ? 0  :
    codec == "zstd"  ? 3  :
    codec == "blosc" ? 5  :
    codec == "zlib"  ? 5  : 0

# Which (backend, codec) combos make sense
function backend_supports(backend, codec)
    if backend in ("mmap", "raw")
        return codec == "none"
    end
    return true
end

# ---------------------------------------------------------------------------
# Run a single configuration
# ---------------------------------------------------------------------------

"""
Returns NamedTuple of:
  write_secs::Vector{Float64} (per repeat)
  read_secs::Vector{Float64}
  on_disk_bytes::Int
"""
function run_config(backend::String, w::Workload, store_path::AbstractString;
                    repeats::Int=3)

    write_secs = Float64[]
    read_secs  = Float64[]
    on_disk    = 0

    # Generate the per-timestep data ONCE, outside the timed loop. The
    # smoothed/bitrounded field generator is expensive (~80–2000 ms for
    # the larger configs) and would otherwise dominate over the actual
    # I/O work for the mmap/raw baselines. Each timestep gets a distinct
    # buffer so cross-chunk compressibility is realistic (a compressor
    # given Nt identical chunks would just compress the first and free-
    # ride on the rest).
    buf_per_step = [gen_data!(Array{Float32}(undef, w.Nx, w.Ny, w.Nz), t) for t in 1:w.Nt]

    # One warm-up + `repeats` timed runs. Each run uses a fresh path.
    nruns_total = 1 + repeats
    for r in 1:nruns_total
        run_path = joinpath(store_path, "run_$(r)")
        mkpath(run_path)
        target = backend == "mmap" || backend == "raw" ?
                 joinpath(run_path, "data.bin") :
                 joinpath(run_path, "data.zarr")

        # ---- write ----
        twrite = @elapsed begin
            if backend == "mmap"
                h = mmap_open_write(w, target)
                for t in 1:w.Nt
                    mmap_write_step!(h, buf_per_step[t], t)
                end
                mmap_close_write(h)
            elseif backend == "raw"
                h = rawio_open_write(w, target)
                for t in 1:w.Nt
                    rawio_write_step!(h, buf_per_step[t], t)
                end
                rawio_close_write(h)
            elseif backend == "zarrjl"
                h = zarrjl_open_write(w, target)
                for t in 1:w.Nt
                    zarrjl_write_step!(h, buf_per_step[t], t)
                end
                zarrjl_close_write(h)
            elseif backend == "zarrsjl"
                h = zarrsjl_open_write(w, target)
                for t in 1:w.Nt
                    zarrsjl_write_step!(h, buf_per_step[t], t)
                end
                zarrsjl_close_write(h)
            else
                error("unknown backend $backend")
            end
        end

        # capture on-disk size from the last (timed) run
        if r == nruns_total
            on_disk = dirsize(target)
        end

        # ---- read ----
        outbuf = Array{Float32}(undef, w.Nx, w.Ny, w.Nz)
        # Re-open as a fresh process-level handle for the read pass.
        tread = @elapsed begin
            if backend == "mmap"
                hr = mmap_open_read(w, target)
                for t in 1:w.Nt
                    mmap_read_step!(hr, outbuf, t)
                end
                mmap_close_read(hr)
            elseif backend == "raw"
                hr = rawio_open_read(w, target)
                for t in 1:w.Nt
                    rawio_read_step!(hr, outbuf, t)
                end
                rawio_close_read(hr)
            elseif backend == "zarrjl"
                hr = zarrjl_open_read(w, target)
                for t in 1:w.Nt
                    zarrjl_read_step!(hr, outbuf, t)
                end
                zarrjl_close_read(hr)
            elseif backend == "zarrsjl"
                hr = zarrsjl_open_read(w, target)
                for t in 1:w.Nt
                    zarrsjl_read_step!(hr, outbuf, t)
                end
                zarrsjl_close_read(hr)
            end
        end

        # Drop warm-up from results
        if r > 1
            push!(write_secs, twrite)
            push!(read_secs,  tread)
        end

        # Clean up this run's files between repeats to avoid filling disk.
        # Keep the LAST run for on-disk size measurement.
        if r != nruns_total
            rm(run_path; recursive=true, force=true)
        end
    end

    return (; write_secs, read_secs, on_disk)
end

# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------

if get(ENV, "ZS_APPEND", "0") == "0"
    isfile(OUT_CSV) && rm(OUT_CSV)
end
header = ["backend", "codec", "Nx", "Ny", "Nz", "Nt",
          "total_bytes", "on_disk_bytes",
          "repeat", "write_sec", "read_sec",
          "write_MBps", "read_MBps",
          "julia_threads", "rayon_threads"]

@printf "==== Sequential time-series benchmark ====\n"
@printf "Sizes:    %d configurations\n"            length(SIZES)
@printf "Codecs:   %s\n"                            join(CODECS, ", ")
@printf "Backends: %s\n"                            join(BACKENDS, ", ")
@printf "Repeats:  %d (+1 warm-up)\n"               REPEATS
@printf "Julia threads: %d\n"                       Threads.nthreads()
@printf "RAYON_NUM_THREADS env: %s\n"               get(ENV, "RAYON_NUM_THREADS", "(unset)")
@printf "Output:   %s\n"                            OUT_CSV

println()

for (Nx, Ny, Nz, Nt) in SIZES
    for codec in CODECS
        chunk = (Nx, Ny, Nz, 1)
        w = Workload(Nx, Ny, Nz, Nt, chunk, codec, codec_level(codec))
        total = total_bytes(w)

        for backend in BACKENDS
            backend_supports(backend, codec) || continue

            store_path = joinpath(TMP_ROOT, "$(backend)_$(codec)_$(Nx)x$(Ny)x$(Nz)x$(Nt)")
            mkpath(store_path)
            @printf "%-8s  codec=%-5s  (%4dx%4dx%4d x%3d)  total=%s ... " backend codec Nx Ny Nz Nt fmt_bytes(total)
            flush(stdout)

            local result
            try
                result = run_config(backend, w, store_path; repeats=REPEATS)
            catch e
                println("FAILED: ", sprint(showerror, e))
                rm(store_path; recursive=true, force=true)
                continue
            end

            wmed = median(result.write_secs)
            rmed = median(result.read_secs)
            wmbps = (total / 1_048_576) / wmed
            rmbps = (total / 1_048_576) / rmed
            @printf "write %.3fs (%.1f MiB/s)  read %.3fs (%.1f MiB/s)  on_disk=%s\n" wmed wmbps rmed rmbps fmt_bytes(result.on_disk)

            # Relabel zarrjl rows if a per-run variant label was passed in.
            # Used by the 4-way comparison (baseline / propA / propB / zarrs)
            # so the CSV can be merged across subprocess runs.
            label = backend == "zarrjl" ? get(ENV, "ZS_ZARRJL_LABEL", "zarrjl") : backend

            for r in 1:REPEATS
                csv_append!(OUT_CSV, header, Any[
                    label, codec, Nx, Ny, Nz, Nt,
                    total, result.on_disk,
                    r,
                    result.write_secs[r],
                    result.read_secs[r],
                    (total / 1_048_576) / result.write_secs[r],
                    (total / 1_048_576) / result.read_secs[r],
                    Threads.nthreads(),
                    get(ENV, "RAYON_NUM_THREADS", ""),
                ])
            end

            rm(store_path; recursive=true, force=true)
        end
    end
end

# Clean up working directory
rm(TMP_ROOT; recursive=true, force=true)
println("\nDone. CSV: ", OUT_CSV)
