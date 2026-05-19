# run_all.jl — convenience driver for the full set of benchmarks.
#
# Usage:
#   julia --project bench/run_all.jl [--quick]
#
# Set environment variables to override sweeps (see each bench_*.jl for
# the env vars it honors).

quick = "--quick" in ARGS

project_dir = dirname(@__DIR__)
julia_bin = Base.julia_cmd()

results_dir = joinpath(project_dir, "results")
mkpath(results_dir)

env_base = copy(ENV)

if quick
    env_base["ZS_SIZES"]   = "64,64,16,10;128,128,32,10;256,256,32,10"
    env_base["ZS_THREADS"] = "1,2,4,8"
    env_base["ZS_REPEATS"] = "2"
end

println("==== ZarrBenchmarks: running all benchmarks ====")
println("Quick mode: ", quick)
println()

println("---- bench_sequential ----")
cmd = setenv(`$julia_bin --project=$project_dir $(joinpath(@__DIR__, "bench_sequential.jl"))`, env_base)
run(cmd)

println()
println("---- bench_threads ----")
cmd = setenv(`$julia_bin --project=$project_dir $(joinpath(@__DIR__, "bench_threads.jl"))`, env_base)
run(cmd)

println()
println("---- bench_compat ----")
cmd = setenv(`$julia_bin --project=$project_dir $(joinpath(@__DIR__, "bench_compat.jl"))`, env_base)
run(cmd)

println()
println("---- plot_results ----")
cmd = setenv(`$julia_bin --project=$project_dir $(joinpath(@__DIR__, "plot_results.jl"))`, env_base)
run(cmd)

println("\nAll done. See $results_dir")
