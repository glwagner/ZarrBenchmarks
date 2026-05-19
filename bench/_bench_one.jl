# Internal: run ONE (backend, codec, size) config and append rows to a CSV.
# Called by bench_threads.jl in a fresh subprocess so that RAYON_NUM_THREADS
# and JULIA_NUM_THREADS take effect at library load time.
#
# Required env: ZS_BACKEND, ZS_CODEC, ZS_SHAPE (Nx,Ny,Nz,Nt), ZS_OUT_CSV, ZS_REPEATS

include(joinpath(@__DIR__, "common.jl"))
using .ZarrBenchCommon
include(joinpath(@__DIR__, "backends.jl"))
using .ZarrBenchBackends

using Printf, Statistics

backend = ENV["ZS_BACKEND"]
codec   = ENV["ZS_CODEC"]
Nx, Ny, Nz, Nt = parse.(Int, split(ENV["ZS_SHAPE"], ','))
repeats = parse(Int, get(ENV, "ZS_REPEATS", "3"))
out_csv = ENV["ZS_OUT_CSV"]
chunk = (Nx, Ny, Nz, 1)

codec_level(codec) =
    codec == "none"  ? 0 :
    codec == "zstd"  ? 3 :
    codec == "blosc" ? 5 :
    codec == "zlib"  ? 5 : 0

w = Workload(Nx, Ny, Nz, Nt, chunk, codec, codec_level(codec))
total = total_bytes(w)
tmp = mktempdir()

buf = Array{Float32}(undef, Nx, Ny, Nz)
gen_data!(buf, 0)

write_secs = Float64[]
read_secs  = Float64[]
on_disk = 0

for r in 0:repeats   # r = 0 is warm-up
    run_path = joinpath(tmp, "run_$(r)")
    mkpath(run_path)
    target = backend in ("mmap", "raw") ? joinpath(run_path, "data.bin") :
                                          joinpath(run_path, "data.zarr")
    twrite = @elapsed begin
        if backend == "mmap"
            h = mmap_open_write(w, target)
            for t in 1:Nt; gen_data!(buf, t); mmap_write_step!(h, buf, t); end
            mmap_close_write(h)
        elseif backend == "raw"
            h = rawio_open_write(w, target)
            for t in 1:Nt; gen_data!(buf, t); rawio_write_step!(h, buf, t); end
            rawio_close_write(h)
        elseif backend == "zarrjl"
            h = zarrjl_open_write(w, target)
            for t in 1:Nt; gen_data!(buf, t); zarrjl_write_step!(h, buf, t); end
            zarrjl_close_write(h)
        elseif backend == "zarrsjl"
            h = zarrsjl_open_write(w, target)
            for t in 1:Nt; gen_data!(buf, t); zarrsjl_write_step!(h, buf, t); end
            zarrsjl_close_write(h)
        else
            error("unknown backend: $backend")
        end
    end

    outbuf = similar(buf)
    tread = @elapsed begin
        if backend == "mmap"
            hr = mmap_open_read(w, target);
            for t in 1:Nt; mmap_read_step!(hr, outbuf, t); end
            mmap_close_read(hr)
        elseif backend == "raw"
            hr = rawio_open_read(w, target);
            for t in 1:Nt; rawio_read_step!(hr, outbuf, t); end
            rawio_close_read(hr)
        elseif backend == "zarrjl"
            hr = zarrjl_open_read(w, target);
            for t in 1:Nt; zarrjl_read_step!(hr, outbuf, t); end
            zarrjl_close_read(hr)
        elseif backend == "zarrsjl"
            hr = zarrsjl_open_read(w, target);
            for t in 1:Nt; zarrsjl_read_step!(hr, outbuf, t); end
            zarrsjl_close_read(hr)
        end
    end

    if r == repeats
        global on_disk = dirsize(target)
    end

    if r > 0
        push!(write_secs, twrite)
        push!(read_secs,  tread)
    end

    if r != repeats
        rm(run_path; recursive=true, force=true)
    end
end

mkpath(dirname(out_csv))
header = ["backend", "codec", "Nx", "Ny", "Nz", "Nt",
          "total_bytes", "on_disk_bytes",
          "repeat", "write_sec", "read_sec",
          "write_MBps", "read_MBps",
          "julia_threads", "rayon_threads"]
for r in 1:repeats
    csv_append!(out_csv, header, Any[
        backend, codec, Nx, Ny, Nz, Nt,
        total, on_disk,
        r,
        write_secs[r], read_secs[r],
        (total / 1_048_576) / write_secs[r],
        (total / 1_048_576) / read_secs[r],
        Threads.nthreads(),
        get(ENV, "RAYON_NUM_THREADS", ""),
    ])
end

@printf "%-8s codec=%-5s shape=%dx%dx%dx%d jl_th=%d rayon=%s  write=%.3fs (%.1f MiB/s)  read=%.3fs (%.1f MiB/s)\n" backend codec Nx Ny Nz Nt Threads.nthreads() get(ENV, "RAYON_NUM_THREADS", "?") median(write_secs) (total/1_048_576)/median(write_secs) median(read_secs) (total/1_048_576)/median(read_secs)

rm(tmp; recursive=true, force=true)
