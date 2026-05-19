# Zarr.jl optimization plan

Driven by the [ZarrBenchmarks](README.md) numbers: on uncompressed sequential
writes Zarr.jl is ~2.5× slower than Zarrs.jl (Rust-backed). On compressed
writes the two libraries match (both bottlenecked by the shared `libzstd`).

This document covers **two complementary proposals**:

- **Proposal A — In-Julia performance fixes to Zarr.jl.** Profile-guided
  patches that close the write gap with no FFI / Rust dependency. The
  headline fix is a single ~10-line change (3× speed-up). Six
  sub-optimizations total, all O(50 LOC), all low-risk.
- **Proposal B — Open Zarr.jl's interface so Zarrs.jl's store can plug in
  as a backend.** Architectural work to make the `AbstractStore` boundary
  swappable. The practical payoff is letting Zarr.jl users opt into the
  Rust [`zarrs`](https://github.com/zarrs/zarrs) crate's storage backends
  (especially S3 / GCS / Icechunk) without losing the rest of the
  Zarr.jl Julia surface. Designed in conversation with the maintainers
  of both libraries.

These aren't either/or. Proposal A makes Zarr.jl fast on the default
filesystem store today. Proposal B opens the door to using Rust where
Rust is genuinely better — i.e. cloud object stores and concurrent I/O —
without taking on Rust as a hard dependency.

## Headline result for Proposal A

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

## Proposal A: In-Julia performance fixes

### Optimization A1 — `pipeline_encode` for `NoCompressor`  ★ critical

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

### Optimization A2 — `getchunkarray` does redundant zero-fill on overwrite paths  ★ easy

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

### Optimization A3 — `writeblock!` spawns 2 tasks per call even for single-chunk writes  ★ medium

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

### Optimization A4 — Skip the readback when the write fully covers the chunk  ★ medium

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

### Optimization A5 — `pipeline_encode` allocation per call (general codec path)

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

### Optimization A6 — `DirectoryStore.setindex!` is open-once-per-chunk

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

## Proposal B: Open Zarr.jl's pipeline so a Zarrs.jl-backed store can plug in

Designed in conversation with the Zarr.jl and Zarrs.jl maintainers
([Joe Hamman](https://github.com/jhamman),
[Mark Kittisopikul](https://github.com/mkitti),
[Felix Cremer](https://github.com/felixcremer)).

### The idea in one sentence

Make Zarr.jl's pipeline pluggable enough that each piece — the storage
backend, the codec pipeline, the metadata layer — can be swapped for an
equivalent component from either Zarr.jl *or* Zarrs.jl, and in practice
let Zarr.jl users opt in to the Rust [`zarrs`](https://github.com/zarrs/zarrs)
crate's storage backends without taking the whole library along.

### Why the store, specifically

After running the benchmarks and patching the obvious Julia hot path
(Proposal A), the rank-ordered list of "things where Rust really is
better" comes out:

1. **Cloud / network storage backends.** `zarrs` builds on the
   `object_store` Rust crate, which has mature, well-tested
   implementations of S3, GCS, Azure Blob, HTTP, and the streaming-friendly
   patterns those services require (concurrent multi-part uploads, byte-range
   reads, retry with backoff, presigned URLs). Zarr.jl's `S3Store` and
   `GCStore` are functional but thinner and (in the maintainers' own
   words) under-loved compared to the filesystem path.
2. **[Icechunk](https://icechunk.io).** A versioned-Zarr-on-object-storage
   spec maintained by Earth Mover with first-class Rust bindings.
   No Julia-native implementation exists; the only path for Julia users
   to get Icechunk read/write is through Zarrs.jl.
3. **Sharding codec.** Already in Zarr.jl as of [#241](https://github.com/JuliaIO/Zarr.jl/pull/241),
   but Zarrs.jl's implementation has had more testing on real datasets.
4. **Concurrent chunk I/O.** `zarrs` uses `rayon` to parallelize chunk
   fetches; Zarr.jl's `ConcurrentRead` strategy (via `asyncmap`) works
   but is task-based rather than threadpool-based and is less effective
   at saturating object-store backends.

Items 1–2 are where the gap is genuinely structural, not a "we just
haven't gotten around to optimizing it" thing. The codec pipeline (item
where Rust *was* assumed to be faster) turns out not to be — see
Proposal A.

So the practical question becomes: *given that we want Zarrs.jl's
store implementations and not much else, can we plug just that piece into
Zarr.jl?*

### What "open the pipeline" means concretely

Zarr.jl already has the right shape for this. The four abstraction
boundaries are:

| Layer | Current type | Pluggable today? | Notes |
|---|---|---|---|
| Storage | `AbstractStore` (`src/Storage/Storage.jl`) | Yes — well-defined interface with `getindex`/`setindex!`/`isinitialized`/`subkeys`/`subdirs`/`storagesize`/`storefromstring` | Already extensible (S3, GCS, HTTP, Zip, Dict, Directory implementations) |
| Codec pipeline | `V2Pipeline` / `V3Pipeline` (`src/pipeline.jl`) | Partly — `Compressor` + `Filter` types pluggable, but encoded as concrete fields on the pipeline | Would need a more open `AbstractPipeline` if we wanted swap at codec granularity |
| Metadata | `MetadataV2` / `MetadataV3` | Concrete | Probably no need to abstract |
| Array | `ZArray <: AbstractDiskArray` | Concrete | Probably no need to abstract |

The store layer is the lowest-friction extension point — it already *is*
abstract — so a `ZarrsStore <: Zarr.AbstractStore` could ship today as
either an extension package or a weak-deps extension inside Zarr.jl, with
no upstream changes required. The other layers can be opened up later
when concrete need appears.

### Concrete component: `ZarrsStore <: Zarr.AbstractStore`

The Zarrs.jl FFI already exposes the right low-level entry points:

- `zarrsCreateStorageFilesystem(path)` → `*StorageHandle`
- `zarrsCreateStorageS3(...)`, `zarrsCreateStorageGCS(...)`, `zarrsCreateStorageHTTP(...)`
- `zarrsJlStorageGet(handle, key)` → `Vec<u8>` (raw get)
- `zarrsJlStorageListDir(handle, prefix)` → list (drives `subkeys`/`subdirs`)
- `zarrsJlArrayEraseChunk(...)` (drives `delete!`)
- write goes through the array-level `zarrsArrayStoreChunk` today; a
  raw `zarrsJlStorageSet(handle, key, bytes)` would need to be added on
  the Zarrs side (small Rust patch — calls `storage.set(StoreKey, Bytes)`)

A wrapper in Julia looks roughly like:

```julia
# ext/ZarrZarrsExt.jl  (or stand-alone package ZarrZarrsStore.jl)
struct ZarrsStore <: Zarr.AbstractStore
    handle::Zarrs.ZarrsStorageHandle   # Ptr-wrapping owning struct
    base_path::String                  # logical prefix inside the store
end

# Construction
ZarrsStore(path::AbstractString; kind=:auto) = ...
# kind ∈ (:filesystem, :s3, :gcs, :http, :icechunk, :auto)

# AbstractStore implementation — each method is a 2–5 line FFI call
function Base.getindex(s::ZarrsStore, key::AbstractString)
    Zarrs.LibZarrs.zarrs_jl_storage_get(s.handle.ptr, joinpath(s.base_path, key))
end

function Base.setindex!(s::ZarrsStore, v::Vector{UInt8}, key::AbstractString)
    Zarrs.LibZarrs.zarrs_jl_storage_set(s.handle.ptr, joinpath(s.base_path, key), v)
end

Zarr.isinitialized(s::ZarrsStore, key) = ...
Zarr.subkeys(s::ZarrsStore, p) = ...
Zarr.subdirs(s::ZarrsStore, p) = ...
Zarr.storefromstring(::Type{ZarrsStore}, s::AbstractString, _) = ZarrsStore(s)
Zarr.store_read_strategy(::ZarrsStore) = Zarr.ConcurrentRead(8)
```

Once that exists, any Zarr.jl operation — `zopen`, `zcreate`, the
DiskArrays-based indexing, `FieldTimeSeries`, all of `xarray-via-PythonCall`
— transparently goes through the Rust store. The Julia codec pipeline
runs in Julia (so Proposal A's optimizations apply); the bytes-on-the-wire
go through Rust.

### What this unlocks

- **Production-grade S3 / GCS / Azure for Zarr.jl users**, by reusing
  `object_store` rather than re-implementing in Julia.
- **Icechunk read/write from Zarr.jl** — currently impossible except
  by using Zarrs.jl directly.
- **`obstore`-style URL pipelining**: e.g. `s3://bucket/path|icechunk://branch.main/`,
  which Zarrs.jl already supports.
- **Faster cloud reads via Rust's `rayon` chunk concurrency** — without
  Zarr.jl having to grow its own threadpool implementation.
- **Cleaner ecosystem story for users**: pick the Julia codecs (mature,
  fast after Proposal A) with the Rust storage (mature for clouds), or
  pick all-Julia for a no-Rust deploy, or all-Rust via Zarrs.jl for
  a Zarrs-shaped API. No silos.

### What this asks of the two libraries

**Zarr.jl side** — almost nothing structural is required, because
`AbstractStore` is already the right abstraction. The likely small
additions:

- A `ZarrsStore` extension (weak dep on `Zarrs`), or a separate
  `ZarrZarrsStore.jl` glue package.
- Maybe one or two extra `AbstractStore` interface methods if Zarrs's
  store has capabilities Zarr.jl doesn't yet model — e.g. **batch
  multi-key get / set** (Rust does this natively, Julia would do one
  FFI call per key today). Optional; not blocking.

**Zarrs.jl side** — also small:

- Make sure the FFI exposes a raw key/value `set` operation, parallel to
  the existing `zarrsJlStorageGet`. (Currently writes go through
  `zarrsArrayStoreChunk` which runs the codec pipeline on the Rust side
  — not what we want when Julia is doing the codecs.)
- Optionally: expose `zarrsJlStorageListPrefix` with a streaming-callback
  variant to support large directories without materialising the whole
  key list.
- Document that `ZarrsStorageHandle` is part of the public FFI, with
  stability commitments (these handles are what Zarr.jl will hold).

**Both sides** — agree on the contract:

- Endianness (Zarrs is little-endian-only on the bytes layer; Zarr.jl
  uses the V3 `bytes` codec — confirm these compose correctly).
- Path separators and percent-encoding of chunk keys.
- Behavior on missing keys (`getindex` returns `nothing` vs. errors).
- Concurrency semantics (what does it mean to read while another rank
  is writing the same key?).

A short interface-compatibility doc, plus the existing W6 compatibility
benchmark (`bench/bench_compat.jl`) extended to round-trip through
`ZarrsStore`, would catch the structural disagreements.

### What this does NOT unlock

- **Codec performance.** Both libraries call the same `libzstd` /
  `libblosc`. There is no FFI shortcut to faster compression; that's
  bound by the C codec library and ultimately by your CPU. Proposal A
  is the relevant lever there.
- **Sharding-codec write performance**, *yet*. Zarrs.jl's sharded
  writes go through `zarrsArrayStoreChunk` which expects to drive the
  whole codec pipeline. To get sharding-via-Rust-codecs *while keeping
  Julia in control of array logic* would require a second integration
  pattern (probably: "expose the sharding codec as a Julia-callable
  Rust function" rather than "use the Rust store"). Out of scope for
  this proposal; sharding-via-Julia-codecs already works in Zarr.jl.

### Risk and reversibility

This proposal *adds* a backend; it doesn't remove anything. A Zarr.jl
user who never `using Zarrs` sees no change. A Zarrs.jl user who never
uses Zarr.jl sees no change. The combined-use case is the new thing,
and it lives behind a `using` statement.

The non-trivial risk is **versioning**: Zarrs.jl is pre-1.0, the
`zarrs` Rust crate is evolving, and the FFI layer (`zarrs_jl_jll`)
isn't yet published as a JLL. A `ZarrsStore` extension would need a
tight compat pin on `Zarrs.jl` and would need to advance with it. This
is normal for extension packages and not a blocker; just a maintenance
cost to flag.

### Suggested first deliverable

A 1–2 day spike that:

1. Adds `zarrsJlStorageSet` to the Zarrs.jl FFI (small Rust patch).
2. Writes a ~150-line `ZarrsStore <: Zarr.AbstractStore` (Julia-only).
3. Extends `bench/bench_compat.jl` to round-trip a small array between
   Zarr.jl-with-`DirectoryStore`, Zarr.jl-with-`ZarrsStore`, and
   Zarrs.jl-native.
4. Adds a `bench_sequential.jl` row for Zarr.jl-with-`ZarrsStore`,
   measured against the existing baselines. Expected result: the
   filesystem case lands between native Zarr.jl and native Zarrs.jl,
   confirming the integration is correct and identifying where the
   cost actually sits.

Steps 1–3 prove the concept; step 4 tells us whether the integration
is worth pursuing further or whether Zarr.jl-native cloud stores
(after Proposal A's optimizations) are good enough.

## What we are NOT proposing (and why)

1. **Replace the Channel-based DiskArrays I/O with synchronous code
   throughout.** The channel infrastructure also drives the
   `ConcurrentRead` strategy used by `S3Store` and `HTTPStore`, where
   it's actually useful. A targeted single-chunk fast path
   (Optimization A3) gets the benefit without restructuring the rest.
2. **Rewrite chunk encoding in Rust** (i.e., add a hot-path
   FFI dependency for codecs). The patched-NoCompressor result shows
   that pure Julia can match or beat Zarrs.jl on writes once the
   `Vector{UInt8}` allocation bug is fixed, so the wrapper-overhead
   premium people sometimes assume Rust pays for is not real here.
   Proposal B uses Rust only for storage backends, not codecs, for
   this reason.
3. **Switch to memory-mapped chunk files.** mmap appears in the benchmark
   for context, but switching the store to mmap would change ordering /
   crash semantics in ways users would have to reason about. The
   ~3.4 GiB/s mmap ceiling on this hardware is also still a long way
   from raw `write()` (~7 GiB/s), so it's not a strictly-better default.

## Suggested ordering

The two proposals are largely independent; pick either or both. Within
each, the rough order is:

**Proposal A (in-Julia fixes — measured throughput wins, no new deps):**

1. **Optimization A1** (NoCompressor pipeline_encode). Stand-alone PR.
   Expected ~3× uncompressed write speed-up. Land first.
2. **Optimization A2** (getchunkarray fast path). Stand-alone PR,
   small. Affects both reads and writes.
3. **Optimization A4** (skip readback on full overwrite). Land before
   A3 — they touch overlapping logic in `writeblock!`.
4. **Optimization A3** (single-chunk fast path in `writeblock!`).
5. **Optimization A5** (scratch buffer threading) — combine with the
   v3 pipeline at the same time; touches both.
6. **Optimization A6** (DirectoryStore mkdir cache). Low priority
   unless benchmarking the many-small-chunks workload.

**Proposal B (Zarrs.jl-store-as-backend — architectural, no
single-machine throughput change expected, unlocks clouds):**

1. **Zarrs.jl FFI patch**: add `zarrsJlStorageSet` (and confirm
   `zarrsJlStorageGet` / `zarrsJlStorageListDir` are stable). Small
   Rust PR.
2. **`ZarrsStore <: Zarr.AbstractStore` glue package** (or weak-deps
   extension inside Zarr.jl). ~150 LOC Julia.
3. **Cross-backend compatibility test** — extend `bench_compat.jl` to
   round-trip through every backend pair.
4. **Cloud-store benchmark** (S3 / GCS / Icechunk) — there's no good
   number to put on this yet because Zarr.jl's existing cloud-store
   implementations are not the right baseline; once the integration
   exists, this becomes the comparison that actually matters.
5. Decide based on (4) whether to deprecate Zarr.jl's native cloud
   stores in favor of the Rust-backed ones, or keep both.

## What this means for `ZarrWriter` in Oceananigans

Three practical implications:

- **Filesystem writes:** the 2.5× gap that motivated thinking about
  Zarrs.jl as a backend appears to be **mostly fixable in Zarr.jl**
  with O(50 LOC) of Proposal A patches. The pure-Julia route is viable
  for v1 of `ZarrWriter` and doesn't need a Rust dependency.
- **Compressed writes:** already at parity (both libraries call the
  same `libzstd`), and compression is a net write *slowdown* on fast
  local SSDs anyway. The defaulting-to-`NoCompressor()` decision in
  the writer plan looks right.
- **Cloud writes:** once Proposal B lands, `ZarrWriter(store =
  ZarrsStore("s3://bucket/path"))` becomes the path to a production
  S3 writer without forcing Oceananigans to take Zarrs.jl as a hard
  dep. The writer's existing `store::AbstractStore` kwarg already
  accommodates this — no API change needed on the Oceananigans side.

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
