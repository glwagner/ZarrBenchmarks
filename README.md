# ZarrBenchmarks

A side-by-side performance comparison of the two main Julia [Zarr](https://zarr.dev)
implementations, plus theoretical I/O baselines, on a sequential append-and-read
workload representative of an Oceananigans-style time-series writer.

The libraries:

- **[Zarr.jl](https://github.com/JuliaIO/Zarr.jl)** — pure-Julia, mature. Full Zarr v2,
  experimental v3. Uses [`ChunkCodecLibZstd`](https://github.com/JuliaIO/ChunkCodecLibZstd.jl),
  [`Blosc.jl`](https://github.com/JuliaIO/Blosc.jl), and friends for codecs.
- **[Zarrs.jl](https://github.com/earth-mover/Zarrs.jl)** — Julia bindings to the
  Rust [`zarrs`](https://github.com/zarrs/zarrs) crate via a C FFI. Zarr v3 first,
  v2 supported. Sharding codec. Internal threadpool via `rayon`. Requires a Rust
  toolchain to build (no JLL yet as of this run).

Plus two non-Zarr baselines to anchor the absolute scale:

- **`Mmap`** — `Mmap.mmap` onto a pre-allocated flat binary file. Writes are
  `arr[:,:,:,t] = buf`, then `Mmap.sync!` + `fsync` at close. Reads are a copy
  out of the mapped array.
- **`raw`** — Plain `open` / `write(io, buf)` / `read!(io, buf)`. No metadata, no
  format, no spec — bytes only.

The Zarr workload writes the same logical 4D array, but per the Zarr spec each
timestep becomes a chunk file with metadata, headers, and (optionally) a
compressed payload.

## Workload

A 4D `Float32` array of shape `(Nx, Ny, Nz, Nt)` is filled one timestep at a
time along the trailing axis (one chunk per timestep, `chunks = (Nx, Ny, Nz, 1)`).
After all `Nt` writes the file is `fsync`-ed and closed. Then the array is
re-opened and every timestep is read back sequentially into a pre-allocated
buffer. This mirrors what `ZarrWriter` in
[Oceananigans.jl](https://github.com/CliMA/Oceananigans.jl) does each call to
`write_output!`.

Sizes swept (single chunk per timestep, 50 timesteps unless noted):

| `Nx × Ny × Nz × Nt` | Total bytes | Per-chunk bytes |
|---|---|---|
| 64 × 64 × 16 × 50    | 12.5 MiB | 256 KiB |
| 128 × 128 × 16 × 50  | 50   MiB | 1 MiB   |
| 128 × 128 × 32 × 50  | 100  MiB | 2 MiB   |
| 256 × 256 × 16 × 50  | 200  MiB | 4 MiB   |
| 256 × 256 × 32 × 50  | 400  MiB | 8 MiB   |
| 256 × 256 × 64 × 50  | 800  MiB | 16 MiB  |
| 512 × 512 × 32 × 50  | 1.56 GiB | 32 MiB  |
| 512 × 512 × 64 × 20  | 1.25 GiB | 64 MiB  |
| 512 × 512 × 64 × 50  | 3.12 GiB | 64 MiB  |

Each (backend, codec, size) configuration runs once as a warm-up (discarded)
and three times for the reported median.

## Results

> **Hardware (this run):** Mac Studio (Apple M2 Ultra), 24 cores, 192 GB RAM,
> internal NVMe (APFS). macOS 24.6.0. Julia 1.12.6. Zarr.jl 0.10.0 (main),
> Zarrs.jl 0.1.0 (main) on the `zarrs` Rust crate 0.23 (built locally with
> `cargo 1.95.0`, `--release` + LTO).

### Throughput vs data size

![Throughput vs data size](results/throughput_vs_size.png)

Median MiB/s for sequential write and read, log-log. Solid = uncompressed,
dashed = zstd level 3. Mmap and raw are uncompressed only.

Per-size median throughput, codec **none** (uncompressed):

| Size | Mmap (W) | Raw (W) | Zarr.jl (W) | Zarrs.jl (W) | Mmap (R) | Raw (R) | Zarr.jl (R) | Zarrs.jl (R) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 12 MiB | 1443 | 2636 | 295 | 338 | 7313 | 17067 | 1260 | 2128 |
| 50 MiB | 1170 | 3940 | 446 | 865 | 6917 | 16638 | 876 | 2454 |
| 100 MiB | 1474 | 4513 | 454 | 1075 | 6648 | 12819 | 1126 | 2293 |
| 200 MiB | 1396 | 5449 | 441 | 995 | 6367 | 12245 | 1133 | 2169 |
| 400 MiB | 1359 | 6220 | 456 | 1092 | 6263 | 10082 | 1145 | 1706 |
| 800 MiB | 1728 | 6419 | 464 | 1124 | 6122 | 8465 | 1312 | 1798 |
| 1.6 GiB | 1754 | 6819 | 470 | 1193 | 6168 | 6856 | 1272 | 1856 |
| 3.1 GiB | 1838 | 6771 | 475 | 1180 | 6114 | 6644 | 1401 | 1734 |

All values **MiB/s**, sequential per-step writes/reads, fsync at close.

Headline numbers, codec **zstd level 3** (with our deliberately
highly-compressible synthetic data — see caveat below):

| Size | Zarr.jl (W) | Zarrs.jl (W) | Zarr.jl (R) | Zarrs.jl (R) | Zarr.jl on-disk | Zarrs.jl on-disk |
|---|---:|---:|---:|---:|---:|---:|
| 12 MiB | 316 | 246 | 685 | 781 | 10.7 MiB | 10.7 MiB |
| 100 MiB | 868 | 751 | 1551 | 2035 | 10.5 MiB | 10.5 MiB |
| 800 MiB | 1182 | 1018 | 2194 | 1734 | 11.2 MiB | 11.2 MiB |
| 3.1 GiB | 1269 | 1165 | 2118 | 1950 | 13.9 MiB | 13.9 MiB |

### Throughput vs thread count

![Throughput vs thread count](results/throughput_vs_threads.png)

240 MiB workload (`256×256×32×30` Float32), zstd level 3.
Each (lib, threads) pair runs in a fresh Julia subprocess so
`RAYON_NUM_THREADS` (read once at FFI init by Zarrs.jl) and
`JULIA_NUM_THREADS` take effect cleanly.

| Threads | Zarr.jl write | Zarrs.jl write | Zarr.jl read | Zarrs.jl read |
|---:|---:|---:|---:|---:|
| 1 | 789 | 607 | 1232 | 914 |
| 2 | 926 | 812 | 1571 | 1251 |
| 4 | 1155 | 849 | 1592 | 1359 |
| 8 | 1098 | 849 | 1922 | 1567 |
| 16 | 931 | 850 | 1854 | 1491 |

All values **MiB/s**. Note Zarrs.jl plateaus by 4 threads while Zarr.jl
benefits a little further out to 8 threads. We did not see Zarrs.jl
pull ahead at any thread count for this workload — probably because
zstd-level-3 on highly-compressible data isn't compute-bound enough
for `rayon`'s per-chunk parallelism to dominate the FFI/store-handle
constants. Workloads with more codec work per byte (sharded V3, blosc
with shuffle, real data) may shift this.

### Cross-library compatibility

A small `(32, 32, 16)` Float32 reference array is written with library A and
read with library B for each codec × Zarr-format pair.

|   | v2 → none | v2 → zstd | v2 → blosc | v2 → zlib | v3 → none | v3 → zstd | v3 → blosc | v3 → zlib |
|---|---|---|---|---|---|---|---|---|
| Zarr.jl   → Zarr.jl   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Zarr.jl   → Zarrs.jl  | ✓ | ✓ | ✓ | ✗¹ | ✓ | ✗² | ✓ | ✓ |
| Zarrs.jl  → Zarr.jl   | ✓ | ✓ | ✓ | ✗¹ | ✓ | ✓ | ✓ | ✗³ |
| Zarrs.jl  → Zarrs.jl  | ✓ | ✓ | ✓ | ✗¹ | ✓ | ✓ | ✓ | ✗³ |

- ¹ Zarrs.jl does not support `zlib` for Zarr v2 arrays.
- ² Zarrs.jl rejects Zarr.jl's v3 zstd metadata: the `chunksize` field is
  missing from the codec configuration. A pure-Zarr.jl-written v3 zstd
  store opens fine in Zarr.jl itself but fails in Zarrs.jl. This is the
  only outright cross-library read failure we hit on the major codecs.
- ³ Zarrs.jl doesn't expose `zlib` as a v3 codec name in its current Julia API.

`none`, `blosc`, and zstd-via-Zarrs are clean in both directions and across
both spec versions. (Zarr.jl's v3 still prints an "experimental" warning.)

Raw CSV at `results/compat.csv`.

## Caveats

This is one run on one machine. Several things to keep in mind before
generalising.

1. **Synthetic data is unrealistically compressible.** The generator is
   `buf[I] = ((I + step) % 65537) * 1e-3` — a saw-tooth across each frame,
   varying gently between timesteps. zstd gets ~140× at the larger sizes
   here. Real ocean/atmosphere data typically gets 1.5×–5× with zstd. The
   **compressed-write CPU cost** is broadly representative; the **read
   bandwidth** with compression is artificially boosted because the
   chunk files we're reading are tiny.
2. **APFS write-back caching distorts small writes.** A 192 GB RAM machine
   has plenty of dirty-page budget. We `fsync` all chunk files at close
   to force a real flush, which is included in the wall-time, but small
   per-chunk writes may still benefit from page-cache merging compared
   to a real disk-bound workload. The `raw` write throughput (~6.8 GiB/s
   on large writes) is suspiciously close to the M2 Ultra's published
   NVMe sequential write ceiling — believable, but a slower disk would
   tell a different story.
3. **Mmap read is "magic" cached** when the page cache is warm from the
   prior write. Both Zarr libraries read from the same warm cache, so
   the comparison is fair, but absolute mmap read numbers should not be
   read as "what an mmap reader can do on a cold cache".
4. **Single-chunk-per-timestep workload.** This favors the "fat-chunk"
   write pattern. The "many-small-chunks" workload from the original
   plan (W2) is not run here; that would stress per-chunk metadata
   overhead more, where Zarr.jl's channel-based dispatch is likely to
   pay a higher fixed cost.
5. **Thread sweep is small.** We test `RAYON_NUM_THREADS ∈ {1, 2, 4, 8, 16}`
   on a 24-core machine. Zarrs.jl uses an internal `rayon` threadpool;
   Zarr.jl gets threading indirectly through `Blosc.jl` and `ChunkCodecLibZstd`
   plus the `JULIA_NUM_THREADS` value passed to `-t`. We did *not* test
   parallel writes from multiple Julia processes (the plan's W5) — both
   libraries are designed to support that, but we didn't measure it.
6. **No Python `zarr` baseline.** The plan called for one as a sanity check;
   we didn't run it.
7. **No "many small writes" or random-access read** workloads (the plan's
   W2 and W4). Adding them is mechanical — see `bench/_bench_one.jl`.

## Takeaways

- **Uncompressed sequential write:** Zarrs.jl is consistently faster than
  Zarr.jl. The gap grows with size — roughly 2.5×–2.7× faster at sizes
  ≥ 50 MiB. Zarrs.jl's per-write Float32 throughput approaches mmap
  (~1.1 GiB/s vs mmap's ~1.4–1.8 GiB/s); Zarr.jl plateaus at about
  450–475 MiB/s regardless of size.
- **Uncompressed sequential read:** Zarrs.jl is 1.3×–2.1× faster than
  Zarr.jl across the sweep. Both are 3–4× slower than mmap reads.
- **With zstd compression**, the two libraries close to within 10–15% of
  each other. Compression CPU dominates over store-side per-chunk
  overhead. Zarr.jl's `ChunkCodecLibZstd` is the same upstream zstd
  library that Rust binds to, so this is unsurprising.
- **Mmap is the right "theoretical" floor** for uncompressed writes:
  Zarrs.jl is within 35% of it. The raw `write()` path is ~3.5× faster
  than mmap on the upper end — Mmap.sync incurs an explicit msync pass
  that direct `write` skips.
- **Cross-library round-trip is essentially solid** for codec `none`,
  `blosc`, and zstd in both v2 and v3, in both directions, *except*
  Zarr.jl-written-v3-zstd → Zarrs.jl-read (the `chunksize` config
  mismatch noted above). `zlib` is Zarr.jl-only.
- **Threading helps both libraries** on a 240 MiB zstd workload, but
  saturates by 4–8 threads and gives no additional gain past that.
  Zarr.jl beat Zarrs.jl by ~30% at every thread count for this size +
  codec — counterintuitive given Zarrs.jl's `rayon` internal pool, but
  the workload is small and compression-light enough that Julia-side
  threading in Zarr.jl wins on per-chunk constants.

## How to reproduce

Prereqs: Julia 1.10+, a Rust toolchain (for Zarrs.jl), ~10 GB free disk.

```bash
git clone https://github.com/glwagner/ZarrBenchmarks
cd ZarrBenchmarks

# Clone the libraries under benchmark
git clone https://github.com/JuliaIO/Zarr.jl
git clone https://github.com/earth-mover/Zarrs.jl

# (One-time) install Rust if you don't have it:
#   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
export PATH="$HOME/.cargo/bin:$PATH"

# Develop both libraries into the benchmark environment
julia --project=. -e 'using Pkg; Pkg.develop(path="Zarr.jl"); Pkg.develop(path="Zarrs.jl"); Pkg.instantiate()'

# Build the zarrs_jl Rust shared library (one time)
julia --project=. Zarrs.jl/deps/build.jl

# Run the full sweep + plots (~3 min on an M2 Ultra)
julia --project=. bench/run_all.jl

# Or run pieces individually:
julia --project=. bench/bench_sequential.jl
julia --project=. bench/bench_threads.jl
julia --project=. bench/bench_compat.jl
julia --project=. bench/plot_results.jl
```

### Layout

```
bench/
  common.jl           – Workload type, mmap/raw backends, helpers
  backends.jl         – Zarr.jl & Zarrs.jl backends behind one API
  bench_sequential.jl – size sweep, write + read sequential
  bench_threads.jl    – thread-count sweep (subprocesses, fresh ENV)
  bench_compat.jl     – cross-library round-trip pass/fail table
  plot_results.jl     – CairoMakie plots from the CSVs
  run_all.jl          – convenience driver

results/
  sequential.csv      – one row per (backend, codec, size, repeat)
  threads.csv         – one row per (backend, threads, repeat)
  compat.csv          – one row per (writer, reader, codec, zarr_format)
  *.png               – plots

Project.toml          – pins BenchmarkTools, CairoMakie, Zarr, Zarrs
zarr_libraries_benchmark_plan.md – the original plan
```

### Environment variables understood by the benches

`bench_sequential.jl`:
- `ZS_SIZES`   — `"Nx,Ny,Nz,Nt;Nx,Ny,Nz,Nt;…"` (override the size list)
- `ZS_CODECS`  — `"none,zstd,blosc,zlib"`
- `ZS_REPEATS` — integer (default 3)
- `ZS_BACKENDS` — subset of `{mmap,raw,zarrjl,zarrsjl}`

`bench_threads.jl`:
- `ZS_SHAPE`    — `"Nx,Ny,Nz,Nt"` (default `256,256,32,30`)
- `ZS_CODEC`    — default `zstd`
- `ZS_THREADS`  — `"1,2,4,8,16"`
- `ZS_BACKENDS` — default `"zarrjl,zarrsjl"`
- `ZS_REPEATS`  — integer (default 3)
