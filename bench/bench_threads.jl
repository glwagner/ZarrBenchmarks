# bench_threads.jl
# ------------------------------------------------------------
# Sweep thread counts and measure throughput.  Each (backend, threads)
# combo runs in a fresh Julia subprocess so RAYON_NUM_THREADS (for
# Zarrs.jl) and JULIA_NUM_THREADS (for Zarr.jl) take effect at library
# load time.
#
# Usage:
#   julia --project bench/bench_threads.jl [out_csv]
#
# Env:
#   ZS_SHAPE   — "Nx,Ny,Nz,Nt" (default: 256,256,32,30 ≈ 240 MiB)
#   ZS_CODEC   — codec (default: zstd)
#   ZS_THREADS — comma-separated list (default: 1,2,4,8,16)
#   ZS_BACKENDS — default: zarrjl,zarrsjl

using Printf

project_dir = dirname(@__DIR__)
out_csv = length(ARGS) >= 1 ? ARGS[1] :
    joinpath(project_dir, "results", "threads.csv")
isfile(out_csv) && rm(out_csv)
mkpath(dirname(out_csv))

shape   = get(ENV, "ZS_SHAPE", "256,256,32,30")
codec   = get(ENV, "ZS_CODEC", "zstd")
threads = String.(split(get(ENV, "ZS_THREADS", "1,2,4,8,16"), ','))
backends = String.(split(get(ENV, "ZS_BACKENDS", "zarrjl,zarrsjl"), ','))
repeats = get(ENV, "ZS_REPEATS", "3")

println("==== Threads benchmark ====")
println("Shape:    ", shape, "   (total bytes = $(prod(parse.(Int, split(shape, ',')))*4))")
println("Codec:    ", codec)
println("Threads:  ", join(threads, ", "))
println("Backends: ", join(backends, ", "))
println("Repeats:  ", repeats)
println("Output:   ", out_csv)
println()

julia_bin = Base.julia_cmd()
one_script = joinpath(@__DIR__, "_bench_one.jl")

for nth in threads
    for backend in backends
        env = copy(ENV)
        env["ZS_BACKEND"]  = backend
        env["ZS_CODEC"]    = codec
        env["ZS_SHAPE"]    = shape
        env["ZS_OUT_CSV"]  = out_csv
        env["ZS_REPEATS"]  = repeats
        env["RAYON_NUM_THREADS"] = nth
        # Julia-side threads — give Zarr.jl a chance (though local DirectoryStore
        # is sequential, so this mostly only affects internal codec libraries).
        env["JULIA_NUM_THREADS"] = nth

        cmd = `$julia_bin --project=$project_dir -t $(nth) $one_script`
        cmd = setenv(cmd, env)
        run(cmd)
    end
end

println("\nDone. CSV: ", out_csv)
