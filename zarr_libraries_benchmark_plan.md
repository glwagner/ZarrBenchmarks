# Zarr.jl vs Zarrs.jl benchmark plan

Independent of Oceananigans. Goal: inform a future decision about which Julia Zarr backend
to depend on, by measuring the two side-by-side on representative workloads. Run on the side
in parallel with `ZarrWriter` implementation; results may shape the v2 of the writer (e.g.,
swap backends, or expose both via a thin abstraction).

## The two libraries

- **[Zarr.jl](https://github.com/JuliaIO/Zarr.jl)** — pure Julia. Mature, full Zarr v2,
  partial v3. The library we plan to use for v1 of `ZarrWriter`.
- **[Zarrs.jl](https://github.com/LSchwerdt/Zarrs.jl)** — Julia bindings to the Rust
  [`zarrs`](https://github.com/LDeakin/zarrs) crate. Newer, claims first-class Zarr v3
  including sharded codecs, and substantially faster compressed I/O via Rust.

(Confirm package URLs and current versions before running — Zarrs.jl is younger and the
API surface may have moved.)

## What we want to know

1. **Write throughput** for big arrays, uncompressed and with a representative codec
   (zstd / blosc-zstd). Does Rust-backed compression deliver the throughput multiplier
   it advertises?
2. **Read throughput**, same axes.
3. **Memory footprint** during writes (peak RSS).
4. **Codec coverage**. Does each library support each of: no compression, zlib, zstd,
   blosc, blosc-zstd, lz4?
5. **Spec coverage**. v2 vs v3, sharded codec support, consolidated metadata.
6. **Concurrency model**. How does each library behave when multiple Julia processes /
   threads write to the same store? Lock-free chunk writes? Any GIL-style serialization
   on the Rust side?
7. **Cross-implementation compatibility**. Can a store written by Zarr.jl be read by
   Zarrs.jl (and vice versa)? By Python `zarr`? By `xarray`?
8. **Failure modes**. Behavior when a write is interrupted; behavior on disk-full;
   behavior when chunk metadata gets out of sync with the store.

## Workloads

Use synthetic data (random or function-generated) — no Oceananigans dependency.

- **W1: Single large chunked array, sequential write.** Shape `(1024, 1024, 256)`, `Float32`,
  100 timesteps appended along the last axis. Chunks `(1024, 1024, 256, 1)`. Two passes:
  no compression, and zstd-level-3.
- **W2: Many small writes.** Same shape as W1, but chunks `(128, 128, 256, 1)` → 64 chunk
  files per write step. Tests metadata overhead and small-file performance.
- **W3: Read full time series.** Reopen W1's store, load all 100 timesteps into a Julia
  array. Same with W2.
- **W4: Random-access read.** Reopen W1, read 100 random timestep indices. Tests metadata
  caching and chunk-locator overhead.
- **W5: Parallel write from N Julia processes.** Each process writes its own chunk-aligned
  slab of the same store. N = 2, 4, 8. Confirms (or refutes) lock-free parallel writes for
  each library.
- **W6: Compatibility round-trips.** Write with library A, read with library B. Both
  directions. For each codec in the intersection of supported codecs.

For each workload, three scenarios per library: a single representative codec plus the
no-compression baseline.

## What to measure

| Workload | Metrics |
|---|---|
| W1, W2, W5 | wall-clock total, per-step latency (median + IQR), on-disk size, peak RSS |
| W3, W4 | wall-clock total, per-access latency (W4 only) |
| W6 | binary pass/fail per (library_A, library_B, codec) triple |

Use `BenchmarkTools.@benchmark` for per-call timings; `Base.@elapsed` plus `/usr/bin/time`
(or `Sys.maxrss()`) for whole-run wall + memory.

## Setup

- One machine, no MPI required. Same physical disk for all runs (rule out filesystem
  noise). SSD strongly preferred — chunk write performance is filesystem-dominated.
- Both libraries on their latest tagged release; pin versions in a `Project.toml` for the
  benchmark folder.
- Warm-up run before timed runs (filesystem cache, JIT).
- Compare against Python `zarr` v3 as a sanity check baseline (one Python script, same
  shapes) — establishes a "reasonable" performance envelope.

## Folder layout

```
benchmark/zarr_libraries/
├── Project.toml             # pins Zarr.jl + Zarrs.jl + BenchmarkTools.jl
├── README.md                # how to run, expected wall times
├── common.jl                # shared random-data generator, timing helpers
├── w1_sequential_write.jl
├── w2_many_small_writes.jl
├── w3_full_read.jl
├── w4_random_read.jl
├── w5_parallel_write.jl
├── w6_compatibility.jl
├── python_baseline.py       # optional, for reference numbers
└── results/                 # generated CSVs, not committed
```

Each script writes a CSV row per (library, codec, workload) and prints a summary.

## Open questions before running

- **Does Zarrs.jl expose a Julia-native API or just call out via FFI for each operation?**
  Affects how much measurement is "Julia ↔ Rust crossing" versus "real I/O." Inspect the
  source before designing W2.
- **Does Zarrs.jl support a `DictStore` equivalent**, or only filesystem? If filesystem-only,
  some workloads need adjustment to ensure we're comparing comparable code paths.
- **What Zarr spec version do we standardize on?** Both libraries support v2; only Zarrs.jl
  has solid v3. Run W1–W4 at v2 for apples-to-apples; add a v3-only Zarrs.jl appendix that
  exercises the sharded codec (Zarr.jl can't do this).

## Decision criteria

After running, the questions that should be answerable:

1. Is Zarrs.jl meaningfully faster (≥2×) for compressed write/read at our typical
   workloads? If yes, plan a `ZarrWriter` v2 that can use it.
2. Is Zarrs.jl's API stable enough to depend on? Check release cadence and recent
   breaking changes.
3. Does cross-library round-trip work cleanly? If yes, users can mix-and-match without
   the writer caring; if no, we'd need to commit to one library or the other for the
   reader.
4. Are there codecs supported by one but not the other that matter for our use case
   (e.g., sharded codec, which is a Zarr v3 feature with significant compression and
   throughput wins for very large arrays)?
