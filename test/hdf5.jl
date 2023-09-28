using VortexPasta.PaddedArrays: PaddedVector, pad_periodic!
using VortexPasta.Filaments
using VortexPasta.FilamentIO
using VortexPasta.BasicTypes: VectorOfVectors
using VortexPasta.BiotSavart
using LinearAlgebra: ⋅
using Test

function init_ring_filament(; R, z, sign)
    tlims = (0.0, 2.0)
    S(t) = Vec3(π + R * cospi(sign * t), π + R * sinpi(sign * t), z)
    (; R, z, sign, tlims, S,)
end

function tangent_streamfunction(fs, ψs_all::VectorOfVectors)
    T = eltype(eltype(eltype(ψs_all)))  # there are many layers of containers...
    @assert T <: Number
    ψt_all = similar(ψs_all, T)  # ψs needs to be a VectorOfVectors
    for (f, ψs, ψt) ∈ zip(fs, ψs_all, ψt_all)
        for i ∈ eachindex(f, ψs, ψt)
            ψt[i] = ψs[i] ⋅ f[i, UnitTangent()]
        end
    end
    ψt_all
end

@testset "FilamentIO: HDF5" begin
    # Copied from the ring collision test.
    R = π / 3  # ring radius
    L = π / 8  # ring distance
    rings = [
        init_ring_filament(; R, z = π - L / 2, sign = +1),
        init_ring_filament(; R, z = π + L / 2, sign = -1),
    ]
    fs = map(rings) do ring
        (; tlims, S,) = ring
        N = 64
        ζs = range(tlims...; length = N + 1)[1:N]
        Filaments.init(ClosedFilament, S.(ζs), CubicSplineMethod())
    end

    Γ = 2.0
    a = 1e-6
    Δ = 1/4
    Ls = (2π, 2π, 2π)
    Ns = (64, 64, 64)
    kmax = (Ns[1] ÷ 2) * 2π / Ls[1]
    α = kmax / 6
    rcut = 4 / α

    params = ParamsBiotSavart(;
        Γ, α, a, Δ, rcut, Ls, Ns,
    )

    cache = @inferred BiotSavart.init_cache(params, fs)

    # Use VectorOfVectors to make things more interesting (this is not necessary, but can be
    # convenient)
    vs = VectorOfVectors(map(similar ∘ nodes, fs))
    ψs = similar(vs)
    fields = (velocity = vs, streamfunction = ψs)
    @inferred BiotSavart.compute_on_nodes!(fields, cache, fs)

    ψt = tangent_streamfunction(fs, ψs)
    foreach(pad_periodic!, vs)
    foreach(pad_periodic!, ψs)
    foreach(pad_periodic!, ψt)

    time = 0.3
    info_str = ["one", "two"]

    @testset "→ refinement = $refinement" for refinement ∈ (1, 3)
        fname = "ring_collision_ref$refinement.hdf"

        # Write results
        FilamentIO.write_vtkhdf(fname, fs; refinement) do io
            io["velocity"] = vs
            io["streamfunction"] = ψs
            io["streamfunction_t"] = ψt
            io["time"] = time
            io["info"] = info_str
        end

        function check_fields(io)
            vs_read = @inferred read(io, "velocity", PointData(), Vec3{Float64})
            ψs_read = @inferred read(io, "streamfunction", PointData(), Vec3{Float64})
            ψt_read = @inferred read(io, "streamfunction_t", PointData(), Float64)

            @test vs == vs_read
            @test ψs == ψs_read
            @test ψt == ψt_read

            # Check that arrays are correctly padded
            for (us, vs) ∈ (vs => vs_read, ψs => ψs_read, ψt => ψt_read)
                for (u, v) ∈ zip(us, vs)
                    @test v isa PaddedVector
                    @test parent(v) == parent(u)  # this also compares "ghost" entries
                end
            end

            # Test reading onto VectorOfVectors
            ψs_alt = similar(ψs)
            @assert ψs_alt != ψs
            @assert ψs_alt isa VectorOfVectors
            read!(io, ψs_alt, "streamfunction")
            @test ψs_alt == ψs
            for (u, v) ∈ zip(ψs, ψs_alt)
                @test v isa PaddedVector
                @test parent(v) == parent(u)  # this also compares "ghost" entries
            end

            # Test reading field data
            time_read = @inferred read(io, "time", FieldData(), Float64)  # this is a vector!
            @test time == only(time_read)

            info_read = read(io, "info", FieldData(), String)
            @test info_str == info_read
        end

        # Read results back
        fs_read = @inferred FilamentIO.read_vtkhdf(
            check_fields, fname, Float64, CubicSplineMethod(),
        )

        @test eltype(eltype(fs_read)) === Vec3{Float64}
        if refinement == 1
            @test fs == fs_read
        else
            @test isapprox(fs, fs_read; rtol = 1e-15)
        end

        fs_read_f32 = @inferred FilamentIO.read_vtkhdf(fname, Float32, CubicSplineMethod())
        @test eltype(eltype(fs_read_f32)) === Vec3{Float32}
        @test fs ≈ fs_read_f32

        # Same without passing a function
        FilamentIO.write_vtkhdf(fname * ".alt", fs; refinement)
        fs_read = FilamentIO.read_vtkhdf(fname * ".alt", Float64, CubicSplineMethod())
        @test fs ≈ fs_read
    end
end
