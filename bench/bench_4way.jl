# bench_4way.jl — sequential-write/read sweep across the four Zarr.jl
# variants (baseline / propA / propB / zarrs). Each variant runs in a
# fresh Julia subprocess so the Zarr.jl package being developed
# in our env can be swapped without re-resolution issues.
#
# Output: results/sequential_4way.csv with backend labels
#   mmap, raw, zarrjl_baseline, zarrjl_propA, zarrjl_propB, zarrsjl
#
# Focus: uncompressed, single-threaded.

using Printf

project_dir = dirname(@__DIR__)
out_csv = joinpath(project_dir, "results", "sequential_4way.csv")
isfile(out_csv) && rm(out_csv)
mkpath(dirname(out_csv))

# Paths to the three Zarr.jl variants
zarrjl_baseline = joinpath(project_dir, "Zarr.jl")             # the existing clone (= upstream master)
zarrjl_propA    = "/Users/gregorywagner/Projects/Zarr.jl-propA"
zarrjl_propB    = "/Users/gregorywagner/Projects/Zarr.jl-propB"

@assert isdir(zarrjl_baseline) "baseline Zarr.jl missing"
@assert isdir(zarrjl_propA)    "propA worktree missing"
@assert isdir(zarrjl_propB)    "propB worktree missing"

# Variants. The "developed_path" gets Pkg.develop'd into the bench env
# before each subprocess runs the sequential bench.
variants = [
    (label = "zarrjl_baseline", developed_path = zarrjl_baseline, backends = "mmap,raw,zarrjl,zarrsjl"),
    (label = "zarrjl_propA",    developed_path = zarrjl_propA,    backends = "zarrjl"),
    (label = "zarrjl_propB",    developed_path = zarrjl_propB,    backends = "zarrjl"),
]

# baseline runs ALL backends (mmap/raw/zarrsjl numbers come from there);
# propA/propB only need to re-run the zarrjl rows.

julia_bin = Base.julia_cmd()

println("==== Four-way Zarr.jl variant comparison ====")
println("Output: ", out_csv)
println("Variants:")
for v in variants
    @printf "  %-18s  ->  %s\n" v.label v.developed_path
end
println()

for v in variants
    println("---- Variant: $(v.label) ----")
    @printf "Pkg.develop(path = %s)\n" v.developed_path

    # Switch the env to this variant's Zarr.jl
    cmd_switch = `$julia_bin --project=$project_dir -e "import Pkg; Pkg.develop(path=\"$(v.developed_path)\")"`
    cmd_switch = setenv(cmd_switch, copy(ENV))
    run(cmd_switch)

    # Run the bench
    env = copy(ENV)
    env["ZS_ZARRJL_LABEL"] = v.label
    env["ZS_BACKENDS"]     = v.backends
    env["ZS_CODECS"]       = "none"
    env["JULIA_NUM_THREADS"] = "1"
    env["RAYON_NUM_THREADS"] = "1"
    # First variant overwrites; subsequent ones append.
    env["ZS_APPEND"] = (v === first(variants)) ? "0" : "1"
    # Proposal B variant routes Zarr.jl writes through the ZarrsStore
    # extension instead of DirectoryStore.
    env["ZS_USE_ZARRS_STORE"] = v.label == "zarrjl_propB" ? "1" : "0"

    bench_script = joinpath(@__DIR__, "bench_sequential.jl")
    cmd_bench = `$julia_bin --project=$project_dir -t 1 $bench_script $out_csv`
    cmd_bench = setenv(cmd_bench, env)
    run(cmd_bench)
end

println("\n==== Done. ====")
println("Wrote: ", out_csv)
