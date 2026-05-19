# bench_compat.jl
# ------------------------------------------------------------
# Cross-implementation compatibility round-trip:
#   For each codec in the intersection of codecs supported by both
#   libraries, write a small array with library A and read it back
#   with library B. Report pass/fail per (writer, reader, codec).
#
# Sources of intentional skew:
#   * Zarr.jl defaults to Zarr v2 metadata; Zarrs.jl defaults to v3.
#     We test BOTH v2 and v3 explicitly.
#
# Usage:
#   julia --project bench/bench_compat.jl [out_csv]

include(joinpath(@__DIR__, "common.jl"))
using .ZarrBenchCommon

using Zarr
using Zarrs
using Printf

const OUT_CSV = length(ARGS) >= 1 ? ARGS[1] :
    joinpath(@__DIR__, "..", "results", "compat.csv")
isfile(OUT_CSV) && rm(OUT_CSV)
mkpath(dirname(OUT_CSV))

const DIMS  = (32, 32, 16)
const CHUNK = (16, 16, 8)

# Reference data — small, deterministic, has both "easy" and "noisy" patterns
function make_data()
    A = Array{Float32}(undef, DIMS...)
    for k in 1:DIMS[3], j in 1:DIMS[2], i in 1:DIMS[1]
        A[i,j,k] = Float32(((i + 13*j + 257*k) % 65537) * 1.0f-3)
    end
    return A
end

REF = make_data()

# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------

function write_zarrjl(path, codec, zarr_format)
    isdir(path) && rm(path; recursive=true, force=true)
    compressor = codec == "none"  ? Zarr.NoCompressor() :
                 codec == "zstd"  ? Zarr.ZstdCompressor() :
                 codec == "blosc" ? Zarr.BloscCompressor() :
                 codec == "zlib"  ? Zarr.ZlibCompressor() :
                 error("bad codec")
    z = Zarr.zcreate(Float32, DIMS...;
        path = path, chunks = CHUNK,
        compressor = compressor,
        zarr_format = zarr_format,
    )
    z[:, :, :] = REF
end

function write_zarrsjl(path, codec, zarr_version)
    isdir(path) && rm(path; recursive=true, force=true)
    if codec == "none"
        # Workaround: Zarrs.jl requires bytes codec; "none" means "no compressor"
        z = Zarrs.zcreate(Float32, DIMS...;
            path = path, chunks = CHUNK,
            compressor = "none",
            zarr_version = zarr_version,
        )
    else
        z = Zarrs.zcreate(Float32, DIMS...;
            path = path, chunks = CHUNK,
            compressor = codec,
            compressor_level = 3,
            zarr_version = zarr_version,
        )
    end
    z[:, :, :] = REF
end

# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

function read_zarrjl(path)
    z = Zarr.zopen(path, "r")
    return Array(z[:, :, :])
end

function read_zarrsjl(path)
    z = Zarrs.zopen(path)
    return Array(z[:, :, :])
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

header = ["writer", "reader", "codec", "zarr_format", "status", "detail"]

CODECS = ["none", "zstd", "blosc", "zlib"]
FORMATS = [2, 3]

println("==== Cross-library compatibility round-trip ====")
println()

function try_roundtrip(writer, reader, codec, zfmt)
    tmp = mktempdir()
    path = joinpath(tmp, "arr.zarr")
    try
        if writer == "zarrjl"
            write_zarrjl(path, codec, zfmt)
        else
            write_zarrsjl(path, codec, zfmt)
        end
    catch e
        rm(tmp; recursive=true, force=true)
        return ("write_fail", sprint(showerror, e))
    end

    data = nothing
    try
        data = reader == "zarrjl" ? read_zarrjl(path) : read_zarrsjl(path)
    catch e
        rm(tmp; recursive=true, force=true)
        return ("read_fail", sprint(showerror, e))
    end

    rm(tmp; recursive=true, force=true)
    if size(data) != size(REF)
        return ("shape_mismatch", "$(size(data)) vs $(size(REF))")
    end
    if !(data ≈ REF)
        maxabs = maximum(abs.(data .- REF))
        return ("value_mismatch", "maxabs=$(maxabs)")
    end
    return ("pass", "")
end

for codec in CODECS
    for zfmt in FORMATS
        for (writer, reader) in [("zarrjl", "zarrjl"),
                                  ("zarrjl", "zarrsjl"),
                                  ("zarrsjl", "zarrjl"),
                                  ("zarrsjl", "zarrsjl")]
            status, detail = try_roundtrip(writer, reader, codec, zfmt)
            @printf "  v%d  %-8s -> %-8s  %-5s : %s%s\n" zfmt writer reader codec status (isempty(detail) ? "" : "  ($(detail[1:min(end,80)]))")
            csv_append!(OUT_CSV, header, Any[writer, reader, codec, zfmt, status, replace(detail, ',' => ';')])
        end
    end
end

println("\nCSV: ", OUT_CSV)
