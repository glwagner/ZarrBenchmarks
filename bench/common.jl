module ZarrBenchCommon

using Mmap
using Random
using Printf
using Statistics

export Workload
export csv_append!, fsync_dir, gen_data, gen_data!, fmt_bytes
export drop_caches_if_possible, free_ram_bytes
export mmap_open_write, mmap_write_step!, mmap_close_write
export mmap_open_read,  mmap_read_step!,  mmap_close_read
export rawio_open_write, rawio_write_step!, rawio_close_write
export rawio_open_read,  rawio_read_step!,  rawio_close_read

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

"""
Fill a 3-D buffer with a *realistic-ish* Float32 field — a stand-in for
spatially-correlated, broad-but-not-flat-spectrum data representative of
real climate / ocean model output.

Recipe:

  1. A sum of a handful of low-frequency cosines with descending
     amplitude (a "red" spectrum), seeded by `step` so timesteps differ.
  2. A small white-noise floor for sub-grid variability.
  3. **Bitrounding** the result to ~12 mantissa bits.

Why bitrounding matters. Both pure smoothed noise and pure cosine fields
have Float32 representations with *dense* low-mantissa bits — every
output value uses all 23 mantissa bits of effectively random information.
zstd can't compress that no matter how smooth the field looks at the
floating-point level (we tested: 5-wide box-smoothed white noise still
only compresses ~1.1×). Real model output behaves differently because the
last ~10 mantissa bits typically carry numerical noise that the consumer
doesn't actually need; if you write to Float32 and then read with any
realistic downstream analysis tolerance, those bits are effectively zero.
Climate-science codecs (SpeedyWeather, xbitinfo, etc.) make this explicit
via "keepbits" — we do the same here.

With `keepbits = 10` (the default), the field compresses ~1.85× with
zstd-3, matching the typical raw-Float32 climate-data ratio. Set the
`ZS_KEEPBITS` env var to override (8→~2.2×, 12→~1.6×, 23→~1.1× = raw).
"""
function gen_data!(buf::Array{Float32,3}, step::Int)
    Nx, Ny, Nz = size(buf)
    rng = Random.MersenneTwister(0x9E3779B9 ⊻ UInt32(step))
    # Five modes, increasing wavenumber and decreasing amplitude — a
    # red-spectrum-ish field.
    wavenumbers = ((0.5f0, 0.3f0, 0.2f0),
                   (1.1f0, 0.7f0, 0.5f0),
                   (2.3f0, 1.9f0, 1.1f0),
                   (4.7f0, 3.7f0, 2.3f0),
                   (9.1f0, 7.3f0, 5.9f0))
    amps = (1.0f0, 0.55f0, 0.30f0, 0.18f0, 0.10f0)
    # Phases vary with step so timesteps differ.
    phases = ntuple(m -> Float32(2π * (Random.rand(rng) + 0.1 * step)), length(amps))
    # Pre-tabulate per-axis cos values for each mode (size O(N_axis * Nmodes)).
    px = [Vector{Float32}(undef, Nx) for _ in amps]
    py = [Vector{Float32}(undef, Ny) for _ in amps]
    pz = [Vector{Float32}(undef, Nz) for _ in amps]
    inv_Nx, inv_Ny, inv_Nz = 1f0/Float32(Nx), 1f0/Float32(Ny), 1f0/Float32(Nz)
    for m in eachindex(amps)
        kx, ky, kz = wavenumbers[m]
        φ = phases[m]
        @inbounds for i in 1:Nx; px[m][i] = cos(2π*kx*(i-1)*inv_Nx + φ);          end
        @inbounds for j in 1:Ny; py[m][j] = cos(2π*ky*(j-1)*inv_Ny + 0.7f0*φ);    end
        @inbounds for k in 1:Nz; pz[m][k] = cos(2π*kz*(k-1)*inv_Nz + 0.3f0*φ);    end
    end

    # Fill buf with the field plus small noise. Noise floor ε is small so
    # most variance is in the cosines, but large enough that the field is
    # not bit-trivially compressible.
    ε = 0.05f0
    noise = Array{Float32}(undef, Nx, Ny, Nz)
    Random.rand!(rng, noise)
    Threads.@threads for k in 1:Nz
        @inbounds for j in 1:Ny
            for i in 1:Nx
                v = 0.0f0
                for m in eachindex(amps)
                    v += amps[m] * px[m][i] * py[m][j] * pz[m][k]
                end
                v += ε * (noise[i,j,k] - 0.5f0) * 2.0f0
                buf[i, j, k] = v
            end
        end
    end

    keepbits = parse(Int, get(ENV, "ZS_KEEPBITS", "10"))
    bitround!(buf, keepbits)
    return buf
end

"""
In-place bitrounding for Float32 — truncate (round toward zero) so only
the top `keepbits` mantissa bits are retained, zeroing the remaining
`23 - keepbits` bits. The sign and exponent are untouched.

This is the rough equivalent of writing values with reduced precision
(e.g. Float16 or a fixed-point format) but keeping the Float32 storage,
which is the standard "make-it-zstd-friendly" trick for climate data.
"""
function bitround!(buf::AbstractArray{Float32}, keepbits::Int)
    0 <= keepbits <= 23 || throw(ArgumentError("keepbits must be in 0:23, got $keepbits"))
    drop = 23 - keepbits
    mask = (typemax(UInt32) << drop) % UInt32
    @inbounds for I in eachindex(buf)
        x = reinterpret(UInt32, buf[I]) & mask
        buf[I] = reinterpret(Float32, x)
    end
    return buf
end

# Generic fallback (used by small smoke tests for 0/1/2-D shapes).
function gen_data!(buf::AbstractArray{Float32}, step::Int)
    rng = Random.MersenneTwister(0x9E3779B9 ⊻ UInt32(step))
    Random.rand!(rng, buf)
    @inbounds for I in eachindex(buf)
        buf[I] = (buf[I] - 0.5f0) * 2.0f0
    end
    return buf
end

# Separable in-place box filter along axis `dim` with radius `r`. Edges
# replicate the nearest in-bounds value.
function box_smooth_axis!(dst::Array{Float32,3}, src::Array{Float32,3}, dim::Int, r::Int)
    Nx, Ny, Nz = size(src)
    w = 2r + 1
    inv_w = 1.0f0 / Float32(w)
    if dim == 1
        Threads.@threads for k in 1:Nz
            for j in 1:Ny
                @inbounds for i in 1:Nx
                    s = 0.0f0
                    for di in -r:r
                        ii = clamp(i + di, 1, Nx)
                        s += src[ii, j, k]
                    end
                    dst[i, j, k] = s * inv_w
                end
            end
        end
    elseif dim == 2
        Threads.@threads for k in 1:Nz
            for j in 1:Ny
                @inbounds for i in 1:Nx
                    s = 0.0f0
                    for dj in -r:r
                        jj = clamp(j + dj, 1, Ny)
                        s += src[i, jj, k]
                    end
                    dst[i, j, k] = s * inv_w
                end
            end
        end
    else
        Threads.@threads for k in 1:Nz
            for j in 1:Ny
                @inbounds for i in 1:Nx
                    s = 0.0f0
                    for dk in -r:r
                        kk = clamp(k + dk, 1, Nz)
                        s += src[i, j, kk]
                    end
                    dst[i, j, k] = s * inv_w
                end
            end
        end
    end
    return dst
end

gen_data(dims, step::Int=0) = gen_data!(Array{Float32}(undef, dims...), step)

"""Best-effort fsync of all chunk files plus the metadata dir on POSIX.
On macOS we don't have `sync(dir)` but per-file fsync is what matters for
APFS write-back. fall back to walking the tree."""
function fsync_dir(path::AbstractString)
    if isfile(path)
        open(path, "r") do io
            ccall(:fsync, Cint, (Cint,), fd(io))
        end
        return
    end
    isdir(path) || return
    for (root, _, files) in walkdir(path)
        for f in files
            full = joinpath(root, f)
            try
                open(full, "r") do io
                    ccall(:fsync, Cint, (Cint,), fd(io))
                end
            catch
            end
        end
    end
end

function fmt_bytes(n::Real)
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    i = 1
    while n >= 1024 && i < length(units)
        n /= 1024
        i += 1
    end
    return @sprintf("%.2f %s", n, units[i])
end

"""Compute current free RAM via vm_stat (macOS) — used to gate dataset sizes."""
function free_ram_bytes()
    try
        if Sys.isapple()
            out = read(`vm_stat`, String)
            page_size = 4096
            m = match(r"page size of (\d+)", out)
            m !== nothing && (page_size = parse(Int, m.captures[1]))
            free_pages = 0
            for line in eachsplit(out, '\n')
                m2 = match(r"^Pages free:\s+(\d+)\.", line)
                if m2 !== nothing
                    free_pages += parse(Int, m2.captures[1])
                end
                m3 = match(r"^Pages inactive:\s+(\d+)\.", line)
                if m3 !== nothing
                    free_pages += parse(Int, m3.captures[1])
                end
            end
            return free_pages * page_size
        end
    catch
    end
    return Sys.free_memory()
end

# Best-effort dirsize for on-disk footprint reporting
function dirsize(path::AbstractString)
    isfile(path) && return filesize(path)
    isdir(path) || return 0
    total = 0
    for (root, _, files) in walkdir(path)
        for f in files
            try
                total += filesize(joinpath(root, f))
            catch
            end
        end
    end
    return total
end
export dirsize

# ---------------------------------------------------------------------------
# Workload spec
# ---------------------------------------------------------------------------

"""
Workload: a 3D field of shape `(Nx, Ny, Nz)` appended `Nt` times along the
trailing axis. `chunk` is the per-timestep chunk shape `(cx, cy, cz, 1)`.
The total on-disk array is `(Nx, Ny, Nz, Nt)`.
"""
struct Workload
    Nx::Int
    Ny::Int
    Nz::Int
    Nt::Int
    chunk::NTuple{4,Int}     # chunks for the 4D (Nx, Ny, Nz, Nt) array; usually (Nx, Ny, Nz, 1)
    codec::String            # "none" | "zstd" | "blosc" | "zlib"
    codec_level::Int
end

bytes_per_frame(w::Workload) = w.Nx * w.Ny * w.Nz * sizeof(Float32)
total_bytes(w::Workload) = bytes_per_frame(w) * w.Nt
export bytes_per_frame, total_bytes

# ---------------------------------------------------------------------------
# Backend dispatch
# ---------------------------------------------------------------------------

# Each backend exposes:
#   open_write(w, path) -> handle   (creates the on-disk array, returns handle)
#   write_step!(handle, buf, t)     (appends timestep t in 1:Nt)
#   close_write(handle)
# and for reads:
#   open_read(w, path) -> handle
#   read_step!(handle, buf, t)
#   close_read(handle)

# ----- mmap (theoretical lower bound) -----

struct MmapHandle
    arr::Array{Float32,4}
    io::IOStream
    path::String
end

function mmap_open_write(w::Workload, path::AbstractString)
    isfile(path) && rm(path; force=true)
    io = open(path, "w+")
    nbytes = total_bytes(w)
    # Pre-allocate the file at full size so mmap covers all timesteps.
    truncate(io, nbytes)
    arr = Mmap.mmap(io, Array{Float32,4}, (w.Nx, w.Ny, w.Nz, w.Nt))
    return MmapHandle(arr, io, String(path))
end

function mmap_write_step!(h::MmapHandle, buf::Array{Float32,3}, t::Int)
    @inbounds h.arr[:, :, :, t] = buf
    return nothing
end

function mmap_close_write(h::MmapHandle)
    Mmap.sync!(h.arr)
    # fsync to push to disk
    ccall(:fsync, Cint, (Cint,), fd(h.io))
    close(h.io)
end

function mmap_open_read(w::Workload, path::AbstractString)
    io = open(path, "r")
    arr = Mmap.mmap(io, Array{Float32,4}, (w.Nx, w.Ny, w.Nz, w.Nt))
    return MmapHandle(arr, io, String(path))
end

function mmap_read_step!(h::MmapHandle, buf::Array{Float32,3}, t::Int)
    @inbounds buf .= view(h.arr, :, :, :, t)
    return nothing
end

mmap_close_read(h::MmapHandle) = close(h.io)

# ----- raw I/O baseline: write/read with Base.write/read on plain file -----
# Slightly different code path than mmap (no page-cache mapping).

mutable struct RawIOHandle
    io::IOStream
    path::String
    bytes_per_frame::Int
end

function rawio_open_write(w::Workload, path::AbstractString)
    isfile(path) && rm(path; force=true)
    io = open(path, "w+")
    RawIOHandle(io, String(path), bytes_per_frame(w))
end

function rawio_write_step!(h::RawIOHandle, buf::Array{Float32,3}, t::Int)
    write(h.io, buf)
    return nothing
end

function rawio_close_write(h::RawIOHandle)
    flush(h.io)
    ccall(:fsync, Cint, (Cint,), fd(h.io))
    close(h.io)
end

function rawio_open_read(w::Workload, path::AbstractString)
    io = open(path, "r")
    RawIOHandle(io, String(path), bytes_per_frame(w))
end

function rawio_read_step!(h::RawIOHandle, buf::Array{Float32,3}, t::Int)
    nelem = w_length_from_buf(buf)
    nb = nelem * sizeof(Float32)
    read!(h.io, buf)
    return nothing
end

w_length_from_buf(buf::Array{Float32,3}) = length(buf)
rawio_close_read(h::RawIOHandle) = close(h.io)

# ---------------------------------------------------------------------------
# CSV writer
# ---------------------------------------------------------------------------

"""
csv_append!(path, header, row) — appends `row` (vector) to `path`, writing
`header` if the file is new.
"""
function csv_append!(path::AbstractString, header::Vector{String}, row::Vector)
    new = !isfile(path)
    open(path, "a") do io
        if new
            println(io, join(header, ","))
        end
        println(io, join(row, ","))
    end
end

end # module
