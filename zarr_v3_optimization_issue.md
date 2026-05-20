## Summary

While benchmarking Zarr v3 write/read performance, I found two optimization opportunities that appear to substantially improve uncompressed V3 performance, especially for sequential full-chunk writes.

This is related to, but distinct from, the V2 `NoCompressor` bulk-copy optimization in #272. The V3-specific gap seems to come from the V3 codec pipeline and the generic chunk write path.

All code links below point at master @ `03270b2`.

## Optimization candidates

### 1. Fast path V3 `BytesCodec` encode/decode

**Current encode.** The V3 `BytesCodec` materializes bytes by reinterpreting + collecting an entire `Vector`:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/src/Codecs/V3/V3.jl#L626-L632

The `reinterpret(UInt8, vec(data)) |> collect` route walks the array element-wise to build the output `Vector{UInt8}` rather than issuing one `memcpy`-equivalent copy. For native-endian dense `Array`s with `isbitstype` element types this can be replaced by a single bulk copy.

**Proposed encode replacement.** Add a method specialized on `::Array` (not `AbstractArray`) that uses a bulk `unsafe_copyto!` for the native-endian path, leaving the bswap path unchanged:

```julia
function _copy_array_bytes(data::Array{T}) where T
    isbitstype(T) || return reinterpret(UInt8, vec(data)) |> collect
    out = Vector{UInt8}(undef, sizeof(data))
    GC.@preserve out data unsafe_copyto!(pointer(out),
                                         Ptr{UInt8}(pointer(data)),
                                         length(out))
    return out
end

function codec_encode(c::BytesCodec, data::Array)
    if _needs_bswap(c.endian)
        return reinterpret(UInt8, bswap.(vec(data))) |> collect
    else
        return _copy_array_bytes(data)
    end
end
```

The original `codec_encode(c::BytesCodec, data::AbstractArray)` stays in place as the fallback (views, lazy arrays, etc.); the new `::Array` method just wins by dispatch for the common dense case.

**Current decode.** Decode also allocates an intermediate typed array and then `copyto!`s the destination:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/src/Codecs/V3/V3.jl#L634-L640

…and that intermediate is consumed by `pipeline_decode!`:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/src/pipeline.jl#L33-L52

For the common shape — `V3Pipeline((), BytesCodec, ())`, native endian, `isbitstype` element — the intermediate array is pure overhead. We can copy bytes straight into the destination.

**Proposed decode replacement.** Add a `pipeline_decode!` specialization for the bytes-only pipeline that does an in-place bulk copy, with a safe fallback for the non-bits / bswap case:

```julia
function pipeline_decode!(p::V3Pipeline{Tuple{},AB,Tuple{}}, output::Array{T},
                          compressed::Vector{UInt8}; fill_value=nothing) where {AB<:Codecs.V3Codecs.BytesCodec,T}
    if !isbitstype(T) || Codecs.V3Codecs._needs_bswap(p.array_bytes.endian)
        arr = Codecs.V3Codecs.codec_decode(p.array_bytes, compressed, T, size(output); fill_value)
        copyto!(output, arr)
        return output
    end
    length(compressed) == sizeof(output) || throw(DimensionMismatch(
        "Encoded byte length $(length(compressed)) does not match output byte size $(sizeof(output))"
    ))
    GC.@preserve output compressed unsafe_copyto!(Ptr{UInt8}(pointer(output)),
                                                  pointer(compressed),
                                                  length(compressed))
    return output
end
```

The generic `pipeline_decode!(::V3Pipeline, …)` stays unchanged and handles any pipeline with array→array codecs, bytes→bytes codecs, or non-`BytesCodec` array→bytes codecs.

**Behavior to preserve: fill-chunk elision.** The existing V3 encode pipeline returns `nothing` when every element of the chunk equals `fill_value`, so the storage layer can skip writing the chunk entirely. In local testing, dropping that check failed this existing test:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/test/v3_codecs.jl#L336-L342

A matching `pipeline_encode` specialization keeps the elision but skips the rest of the generic loop:

```julia
function pipeline_encode(p::V3Pipeline{Tuple{},AB,Tuple{}}, data::Array, fill_value) where {AB<:Codecs.V3Codecs.BytesCodec}
    if fill_value !== nothing && all(isequal(fill_value), data)
        return nothing
    end
    return Codecs.V3Codecs.codec_encode(p.array_bytes, data)
end
```

### 2. Direct full-chunk overwrite path

**Current write path.** `writeblock!` is shared by partial and full-chunk writes. For every chunk it touches, it reads the existing chunk (or fills the buffer with `fill_value`), copies user data into a scratch chunk buffer, routes through a read/write channel pair, and then encodes the scratch buffer — even when the caller is overwriting an entire chunk and none of that machinery is needed:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/src/ZArray.jl#L205-L262

The terminal `store_writechunk` it eventually reaches is just:

https://github.com/JuliaIO/Zarr.jl/blob/03270b25e075a9132933559591f5be5bd1c3d512/src/Storage/Storage.jl#L84

**Proposed replacement.** Add a guarded fast path that bypasses the channels and scratch buffer when the write is exactly one full chunk and the input is itself chunk-shaped:

```julia
function _same_indices_as_axes(ranges, a::AbstractArray{<:Any,N}) where N
    all(ntuple(i -> first(ranges[i]) == first(axes(a, i)) &&
                    last(ranges[i]) == last(axes(a, i)), N))
end

function write_full_chunk_direct!(ain::AbstractArray{<:Any,N}, z::ZArray{<:Any,N},
                                  r::CartesianIndices{N}, blockr, input_base_offsets) where N
    length(blockr) == 1 || return false           # exactly one chunk touched
    Missing <: eltype(ain) && return false        # SenMissArray path stays generic

    bI = first(blockr)
    current_chunk_offsets = map((s, i) -> s * (i - 1), z.metadata.chunks, Tuple(bI))
    indranges = map(boundint, r.indices, z.metadata.chunks, current_chunk_offsets)
    length.(indranges) == z.metadata.chunks || return false  # write spans whole chunk

    input_ranges = dotminus.(indranges, input_base_offsets)
    size(ain) == z.metadata.chunks || return false           # input is chunk-shaped
    _same_indices_as_axes(input_ranges, ain) || return false # …and aligned to it

    data_encoded = compress_raw(maybeinner(ain), z)
    if data_encoded === nothing
        # fill-chunk elision: delete any existing chunk on disk
        if store_isinitialized(z.storage, z.path, bI, z.metadata.chunk_key_encoding)
            store_deletechunk(z.storage, z.path, bI, z.metadata.chunk_key_encoding)
        end
    else
        store_writechunk(z.storage, data_encoded, z.path, bI, z.metadata.chunk_key_encoding)
    end
    return true
end
```

…and an early return at the top of `writeblock!`:

```julia
function writeblock!(ain::AbstractArray{<:Any,N}, z::ZArray{<:Any,N}, r::CartesianIndices{N}) where {N}
    z.writeable || error("Can not write to read-only ZArray")
    input_base_offsets = map(i -> first(i) - 1, r.indices)
    blockr = CartesianIndices(map(trans_ind, r.indices, z.metadata.chunks))

    if write_full_chunk_direct!(ain, z, r, blockr, input_base_offsets)
        return ain
    end
    # …existing channel/scratch-buffer path unchanged from here…
end
```

Every guard (`length(blockr) == 1`, full-chunk span, chunk-shaped input, aligned ranges, no `Missing`) falls back to the current implementation when violated. Partial writes, multi-chunk writes, missing-element arrays, and non-exact ranges all stay on the existing path.

A small companion change avoids paying a `fill!` for the scratch buffer when the existing path *is* taken but `fill_value` is set (the buffer gets initialised explicitly later anyway):

```julia
function getchunkarray_undef(z::ZArray{T}) where {T}
    Missing <: T && return getchunkarray(z)  # SenMissArray inner buffer needs zero-init
    return Array{T}(undef, z.metadata.chunks)
end

# in writeblock!:
a = z.metadata.fill_value === nothing ? getchunkarray(z) : getchunkarray_undef(z)
```

This is independent of the fast-path guard and could be split out further if preferred.

## Local benchmark results

Single-threaded, V3, `NoCompressor`, one chunk per timestep, 1 warm-up + 3 timed repeats. Throughput is MiB/s (median of the 3 timed repeats).

| Size | Optimized Zarr.jl write | Zarrs.jl write | Write ratio | Optimized Zarr.jl read | Zarrs.jl read | Read ratio |
|---|---:|---:|---:|---:|---:|---:|
| 64x64x16x50 | 382 | 360 | 1.06x | 1056 | 1879 | 0.56x |
| 128x128x16x50 | 1489 | 931 | 1.60x | 1509 | 2418 | 0.62x |
| 128x128x32x50 | 2331 | 1145 | 2.04x | 1608 | 2122 | 0.76x |
| 256x256x16x50 | 2974 | 1282 | 2.32x | 1037 | 2177 | 0.48x |
| 256x256x32x50 | 3577 | 1075 | 3.33x | 1484 | 2367 | 0.63x |
| 256x256x64x50 | 3709 | 1285 | 2.89x | 1613 | 1736 | 0.93x |
| 512x512x32x50 | 3727 | 1253 | 2.97x | 1517 | 1962 | 0.77x |
| 512x512x64x20 | 3828 | 1346 | 2.84x | 1526 | 1855 | 0.82x |
| 512x512x64x50 | 3744 | 1253 | 2.99x | 1664 | 1977 | 0.84x |

Across these sizes, the optimized local branch was about 2.3x geomean faster than Zarrs.jl on writes. Reads improved from the V3 bytes fast path, but Zarrs.jl was still faster overall on reads.

## Validation so far

A local experiment branch preserving fill-chunk elision passed the V3 codec suite:

```text
test/v3_codecs.jl: 182/182 passed
```

Also tested full-write and partial-write smoke cases to verify the exact full-chunk path falls back correctly for partial writes.

## Proposed next step

If this direction sounds reasonable, I think this should probably be split into two PRs:

1. V3 `BytesCodec` encode/decode fast paths (the `::Array` method on `codec_encode`, plus the `pipeline_encode` / `pipeline_decode!` specializations for `V3Pipeline{Tuple{},BytesCodec,Tuple{}}`).
2. Exact full-chunk overwrite fast path in `writeblock!` (the `write_full_chunk_direct!` guard).

The first is smaller and lower risk; the second is the larger V3 write-side win.
