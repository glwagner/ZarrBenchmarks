# Zarr.jl optimization plan

Driven by the [ZarrBenchmarks](README.md) numbers: on uncompressed sequential
writes Zarr.jl is ~2.5× slower than Zarrs.jl (Rust-backed). On compressed
writes the two libraries match (both bottlenecked by the shared `libzstd`).

This document identifies the specific code paths responsible, with measured
per-fix impact from local patching experiments.

## Headline result

A **single ~10-line change** to `Zarr.jl/src/pipeline.jl` brings Zarr.jl
from 460 → **1406 MiB/s** on uncompressed writes (256×256×32 chunks),
matching and slightly exceeding Zarrs.jl (~1200 MiB/s). That's the
biggest, easiest, lowest-risk win and worth landing first.

The remaining wins (~10–30% each) sit in the read side and the
read-modify-write framing of `writeblock!`. None of them require touching
the public API.

## Bottleneck inventory (uncompressed write, 256×256×32×Float32 = 8 MiB chunks)

CPU profile of 50 timestep writes (samples ≈ ms):

| Stack frame | Samples | % | What it's doing |
|---|---:|---:|---|
| `compress_raw` → `pipeline_encode` → `zcompress!` → `append!` | 433 | **67%** | Element-wise `push!` of bytes into a fresh `Vector{UInt8}` — for NoCompressor! |
| `getchunkarray` → `fill(0f0, chunks)` | 70 | 11% | Allocating + zeroing a chunk-sized buffer per call |
| `materialize!` / `copyto!` (user → chunk) | 133 | 21% | The actual user-data → chunk-buffer memcpy |
| `Channel`-mediated async readtask/writetask | not isolated | small | Per-chunk task spawn + channel sync |

Per-call allocations: **~16.8 MB for an 8 MiB chunk write** (2× the data
volume going through GC).

## Optimization 1 — `pipeline_encode` for `NoCompressor`  ★ critical

**Location:** [`src/pipeline.jl:1-8`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/pipeline.jl#L1-L8) and
[`src/Compressors/Compressors.jl:33-36`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/Compressors/Compressors.jl#L33-L36).

**Current behaviour.** The V2 encode pipeline allocates a fresh
`UInt8[]`, then dispatches to a generic `zcompress!(compressed, data, c)`
that does:

```julia
function zcompress!(compressed, data, c)
    empty!(compressed)
    append!(compressed, zcompress(data, c))   # for NoCompressor: append a reinterpret view
end
```

For `NoCompressor`, `zcompress` returns a `reinterpret(UInt8, data)` *view*.
The `append!` then walks the view element-by-element through `_growend!` /
`push!` / `_append!`, materialising the bytes one at a time. The profile
shows this path at **67% of write CPU**. It also drives most of the per-call
allocation budget.

**Fix.** Add a `NoCompressor`-specific encode that does a bulk byte copy:

```julia
function pipeline_encode(p::V2Pipeline, data::AbstractArray, fill_value)
    if p.compressor isa NoCompressor && p.filters === nothing
        # bulk path: reinterpret + copyto!, no append! growth
        n = sizeof(data)
        out = Vector{UInt8}(undef, n)
        GC.@preserve out data unsafe_copyto!(pointer(out),
                                             Ptr{UInt8}(pointer(data)), n)
        return out
    end
    # ... existing path ...
end
```

Or equivalently fix the generic `zcompress!` to allocate-then-bulk-copy:

```julia
function zcompress!(compressed, data, c)
    src = zcompress(data, c)   # reinterpret view
    resize!(compressed, length(src))
    copyto!(compressed, src)   # SIMD / memcpy under the hood
end
```

**Also remove the `all(isequal(fill_value), data)` scan.** It walks the
whole chunk to detect an all-fill-value buffer and write nothing —
plausibly worth it for sparse data, but on a `fill_value=0f0` write with
real data this is a full 8 MiB scan per chunk that always returns false.
Guard it behind a heuristic ("only scan if `length(data) < CHEAP_THRESHOLD`")
or drop entirely; users that care can call a dedicated `write_sparse`.

**Measured impact:** 460 → **1406 MiB/s** (3.06× speed-up) on the
256×256×32×50 benchmark with a 10-line local patch. The same fix lifts
zstd-3 writes a smaller amount (~7%) because compression CPU dominates.

**Risk:** Very low. The new encode is semantically identical to the old
one (bytes-on-disk are bit-identical). The all-fill-value scan removal
*changes behavior* for sparse data — chunks that previously were elided
will now be written. Easy mitigation: keep the scan, but only run it
when `fill_value !== nothing` and the data type is `<: Number` (skip on
the hot path for dense writes).

## Optimization 2 — `getchunkarray` does redundant zero-fill on overwrite paths  ★ easy

**Location:** [`src/ZArray.jl:161`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/ZArray.jl#L161).

```julia
getchunkarray(z::ZArray) = fill(_zero(eltype(z)), z.metadata.chunks)
```

This allocates a fresh array of the chunk shape and **zero-fills it**.
For a full-chunk overwrite (the common case: the chunk boundary matches
the requested write region), the zero is immediately overwritten and
serves no purpose. The zero-fill costs an 8 MiB memset per chunk on our
default workload — about 5–8% of the patched write time.

**Fix.** Split into two: an `undef` variant for full-overwrites, and the
existing zero-fill variant for partial-chunk RMW. `writeblock!` already
knows whether the indranges fully cover the chunk
([`ZArray.jl:238-246`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/ZArray.jl#L238-L246))
so the dispatch is trivial:

```julia
getchunkarray_undef(z::ZArray) = Array{eltype(z)}(undef, z.metadata.chunks)

# in writeblock! around line 213:
a = isfullchunk ? getchunkarray_undef(z) : getchunkarray(z)
```

Also applies to `readblock!` — every read path allocates and zero-fills,
then overwrites. There's no scenario in `readblock!` where the zero-fill
isn't immediately clobbered.

**Measured impact:** small but real. Removing the fill from `readblock!`
in a smoke test took the uncompressed read from 1260 → ~1450 MiB/s
(~15%). Write side adds another few %.

**Risk:** Low. The `resetbuffer!` path inside `writeblock!` already
re-fills the buffer with `fill_value` when needed.

## Optimization 3 — `writeblock!` spawns 2 tasks per call even for single-chunk writes  ★ medium

**Location:** [`src/ZArray.jl:215-227`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/ZArray.jl#L215-L227).

The current write path spawns `readtask` (to fetch each chunk for RMW)
and `writetask` (to push to the store), with both communicating via
`Channel(0)`. For our common case (full-chunk write, 1 chunk per call),
this is two `@async` task spawns and four `put!`/`take!` operations
to move ~8 MiB through.

**Fix.** Add a fast path in `writeblock!` for single-chunk, full-overwrite
writes that skips the channels entirely:

```julia
if length(blockr) == 1 && length.(indranges) == size(a)
    bI = first(blockr)
    a .= view(ain, ...)   # already aligned
    bytes = compress_raw(maybeinner(a), z)
    store_writechunk(z.storage, bytes, z.path, bI, z.metadata.chunk_key_encoding)
    return ain
end
```

**Estimated impact:** ~5–10%. The async-task overhead is real but small
on M-series CPUs (~10 µs per task spawn).

**Risk:** Low. The slow path is preserved exactly. Concurrency semantics
unchanged (a single-chunk write was effectively sequential anyway).

## Optimization 4 — Skip the readback when the write fully covers the chunk  ★ medium

**Location:** [`src/ZArray.jl:217-219`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/ZArray.jl#L217-L219).

`writeblock!` always spawns a `readtask` that calls `store_readchunk` for
every target chunk, even when the user is overwriting the chunk entirely.
For new chunks that don't exist yet (the common case in append-along-time
workloads), this is a wasted stat + (no) read. For chunks that *do*
exist and are being fully overwritten, it's a wasted file read.

**Fix.** Compute `isfullchunk` per chunk index, and feed `nothing` into
the writeblock loop's RMW logic for chunks that are fully covered. The
current logic at line 248 (`if chunk_compressed !== nothing`) already
handles `nothing` gracefully.

**Estimated impact:** medium. On our benchmark the chunks don't exist
yet so each readback returns `nothing` after a `stat`. On a re-write
workload (overwriting an existing store), this avoids reading the
entire on-disk array back into memory before clobbering it.

**Risk:** Medium-low. Need to be sure the `isfullchunk` calculation
matches what `writeblock!` does downstream. Worth a unit test.

## Optimization 5 — `pipeline_encode` allocation per call (general codec path)

**Location:** [`src/pipeline.jl:1-8`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/pipeline.jl#L1-L8).

`pipeline_encode` always allocates a fresh `dtemp = UInt8[]` per
chunk, even for the Blosc/zstd path. For sustained writes, this
buffer could be passed through from the caller (or cached on the
ZArray) and reused.

**Fix.** Plumb a scratch buffer through `writeblock!`. The
`pipeline_encode` signature becomes:

```julia
pipeline_encode(p::V2Pipeline, data, fill_value;
                scratch::Vector{UInt8} = UInt8[])
```

The scratch is cleared at function entry, written into, and returned.
For zstd this means the per-chunk `Vector{UInt8}` growth becomes a
`resize!` against a stable, monotonically-growing buffer.

**Estimated impact:** ~5–10% for zstd (compression CPU still
dominates). Larger for Blosc with shuffle.

**Risk:** Low, but touches more files.

## Optimization 6 — `DirectoryStore.setindex!` is open-once-per-chunk

**Location:** [`src/Storage/directorystore.jl:29-35`](https://github.com/JuliaIO/Zarr.jl/blob/main/src/Storage/directorystore.jl#L29-L35).

Each chunk write does:

```julia
function Base.setindex!(d::DirectoryStore,v,i::String)
    fname = d.folder * "/" * i
    folder = dirname(fname)
    isdir(folder) || mkpath(folder)
    write(fname, v)
    v
end
```

The `isdir(folder) || mkpath(folder)` is a stat syscall *every* write,
even after the parent directory has been created hundreds of times. On
APFS that's a few microseconds per chunk, but it does add up for the
many-small-chunks workload (the original plan's W2 — which we haven't
benchmarked here).

**Fix.** Cache the set of created parent dirs in the `DirectoryStore`
struct (an `IdSet{String}` mutable field), or just skip the stat for
the path the previous chunk used.

**Estimated impact:** ~1% for our benchmark, but plausibly 10%+ on
the W2 many-small-chunks workload.

**Risk:** Low. The cache is purely additive; correctness preserved.

## What we are NOT proposing (and why)

1. **Replace the Channel-based DiskArrays I/O with synchronous code
   throughout.** The channel infrastructure also drives the
   `ConcurrentRead` strategy used by `S3Store` and `HTTPStore`, where
   it's actually useful. A targeted single-chunk fast path
   (Optimization 3) gets the benefit without restructuring the rest.
2. **Rewrite chunk encoding in Rust** (i.e., add a hot-path
   FFI dependency). The patched-NoCompressor result shows that pure
   Julia can match or beat Zarrs.jl on writes, so the wrapper overhead
   premium people sometimes assume Rust pays for is not real here.
3. **Switch to memory-mapped chunk files.** mmap appears in the benchmark
   for context, but switching the store to mmap would change ordering /
   crash semantics in ways users would have to reason about. The
   ~3.4 GiB/s mmap ceiling on this hardware is also still a long way
   from raw `write()` (~7 GiB/s), so it's not a strictly-better default.

## Suggested ordering

1. **Optimization 1** (NoCompressor pipeline_encode). Stand-alone PR.
   Expected ~3× uncompressed write speed-up. Land first.
2. **Optimization 2** (getchunkarray fast path). Stand-alone PR,
   small. Affects both reads and writes.
3. **Optimization 4** (skip readback on full overwrite). Land before
   #3 — they touch overlapping logic in `writeblock!`.
4. **Optimization 3** (single-chunk fast path in `writeblock!`).
5. **Optimization 5** (scratch buffer threading) — combine with the
   v3 pipeline at the same time; touches both.
6. **Optimization 6** (DirectoryStore mkdir cache). Low priority unless
   benchmarking the many-small-chunks workload.

## What this means for `ZarrWriter` in Oceananigans

Two practical implications:

- The 2.5× uncompressed-write performance gap that motivated thinking
  about Zarrs.jl as a backend appears to be **mostly fixable in
  Zarr.jl** with O(50 LOC) of targeted patches. The pure-Julia route
  is viable for v1 of `ZarrWriter` and doesn't need a Rust dependency.
- The compressed-write story is already at parity (both libraries call
  the same `libzstd`), and **compression is a net write *slowdown* on
  fast local SSDs anyway**, per the ZarrBenchmarks result. The
  defaulting-to-`NoCompressor()` decision in the writer plan looks
  right.

## Reproducing

The patched-NoCompressor A/B test is reproducible from the benchmark
repo:

```julia
using Zarr, BenchmarkTools
include("bench/common.jl"); using .ZarrBenchCommon

# Monkey-patch in-process
function Zarr.pipeline_encode(p::Zarr.V2Pipeline, data::AbstractArray, fill_value)
    if p.compressor isa Zarr.NoCompressor && p.filters === nothing
        n = sizeof(data)
        out = Vector{UInt8}(undef, n)
        GC.@preserve out data unsafe_copyto!(pointer(out),
                                             Ptr{UInt8}(pointer(data)), n)
        return out
    end
    dtemp = UInt8[]
    Zarr.zcompress!(dtemp, data, p.compressor, p.filters)
    return dtemp
end

# Now run any bench script — uncompressed writes are 3× faster
```

The full investigation (clone, profile, A/B test, patch, re-measure) is
~30 minutes of work and worth doing on the Zarr.jl side for any
contributor opening these PRs.
