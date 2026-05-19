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

"""Fill a buffer with deterministic values (avoids randomness inside the
timed window). Pattern depends on a step index so consecutive timesteps
write different bytes — keeps the compressor honest."""
function gen_data!(buf::AbstractArray{Float32}, step::Int)
    Threads.@threads for I in eachindex(buf)
        @inbounds buf[I] = Float32((I + step) % 65537) * 1.0f-3
    end
    return buf
end

gen_data(dims, step::Int=0) = gen_data!(Array{Float32}(undef, dims), step)

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
