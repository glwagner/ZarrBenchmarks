module ZarrBenchBackends

using Zarr
using Zarrs

# Caller must have already `include`d common.jl and brought `ZarrBenchCommon`
# into Main. We reference it by absolute path to avoid double-loading the
# module (two copies of `Workload` etc.).
using ..ZarrBenchCommon

export ZarrJlHandle, ZarrsJlHandle
export zarrjl_open_write, zarrjl_write_step!, zarrjl_close_write
export zarrjl_open_read,  zarrjl_read_step!,  zarrjl_close_read
export zarrsjl_open_write, zarrsjl_write_step!, zarrsjl_close_write
export zarrsjl_open_read,  zarrsjl_read_step!,  zarrsjl_close_read

# ---------------------------------------------------------------------------
# Zarr.jl backend
# ---------------------------------------------------------------------------

mutable struct ZarrJlHandle
    z::Any           # Zarr.ZArray
    path::String
    Nx::Int
    Ny::Int
    Nz::Int
end

function zarrjl_compressor(codec::AbstractString, level::Int)
    codec == "none"  && return Zarr.NoCompressor()
    codec == "zstd"  && return Zarr.ZstdCompressor(; level=level)
    codec == "zlib"  && return Zarr.ZlibCompressor(level)
    codec == "blosc" && return Zarr.BloscCompressor(; clevel=level)
    error("Unknown codec for Zarr.jl: $codec")
end

function zarrjl_open_write(w::Workload, path::AbstractString)
    isdir(path) && rm(path; recursive=true, force=true)
    # Start with the array at full size — matches the spec'd workload "append Nt frames".
    # We use the same allocation pattern as Oceananigans' growing-time-axis: create
    # with Nt = w.Nt up-front (cheap on disk — no chunk files written until data is set).
    compressor = zarrjl_compressor(w.codec, w.codec_level)
    z = Zarr.zcreate(Float32, w.Nx, w.Ny, w.Nz, w.Nt;
        path = path,
        chunks = w.chunk,
        compressor = compressor,
        fill_value = 0f0,
    )
    return ZarrJlHandle(z, String(path), w.Nx, w.Ny, w.Nz)
end

function zarrjl_write_step!(h::ZarrJlHandle, buf::Array{Float32,3}, t::Int)
    # Single-chunk per timestep (chunks[4] == 1) gives the cleanest path.
    h.z[:, :, :, t] = buf
    return nothing
end

function zarrjl_close_write(h::ZarrJlHandle)
    # Zarr.jl flushes on each setindex via the storage backend. Force fsync of
    # all on-disk chunk files for fairness with the mmap/raw backends.
    fsync_dir(h.path)
end

function zarrjl_open_read(w::Workload, path::AbstractString)
    z = Zarr.zopen(path, "r")
    return ZarrJlHandle(z, String(path), w.Nx, w.Ny, w.Nz)
end

function zarrjl_read_step!(h::ZarrJlHandle, buf::Array{Float32,3}, t::Int)
    @inbounds buf .= h.z[:, :, :, t]
    return nothing
end

zarrjl_close_read(h::ZarrJlHandle) = nothing

# ---------------------------------------------------------------------------
# Zarrs.jl backend
# ---------------------------------------------------------------------------

mutable struct ZarrsJlHandle
    z::Any           # Zarrs.ZarrsArray
    path::String
    Nx::Int
    Ny::Int
    Nz::Int
end

function zarrsjl_open_write(w::Workload, path::AbstractString)
    isdir(path) && rm(path; recursive=true, force=true)
    z = Zarrs.zcreate(Float32, w.Nx, w.Ny, w.Nz, w.Nt;
        path = path,
        chunks = w.chunk,
        compressor = w.codec,
        compressor_level = w.codec_level,
        fill_value = 0f0,
    )
    return ZarrsJlHandle(z, String(path), w.Nx, w.Ny, w.Nz)
end

function zarrsjl_write_step!(h::ZarrsJlHandle, buf::Array{Float32,3}, t::Int)
    h.z[:, :, :, t] = buf
    return nothing
end

function zarrsjl_close_write(h::ZarrsJlHandle)
    fsync_dir(h.path)
end

function zarrsjl_open_read(w::Workload, path::AbstractString)
    z = Zarrs.zopen(path)
    return ZarrsJlHandle(z, String(path), w.Nx, w.Ny, w.Nz)
end

function zarrsjl_read_step!(h::ZarrsJlHandle, buf::Array{Float32,3}, t::Int)
    @inbounds buf .= h.z[:, :, :, t]
    return nothing
end

zarrsjl_close_read(h::ZarrsJlHandle) = nothing

end # module
