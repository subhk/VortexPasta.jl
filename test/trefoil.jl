using Test
using LinearAlgebra: norm, ⋅
using VortexPasta.Filaments
using VortexPasta.BiotSavart

function init_trefoil_filament(N::Int)
    R = π / 4
    S(t) = R .+ R .* Vec3(
        2 + sinpi(t) + 2 * sinpi(2t),
        2 + cospi(t) - 2 * cospi(2t),
        -sinpi(3t),
    )
    ζs = range(0, 2; length = N + 1)[1:N]
    Filaments.init(ClosedFilament, S.(ζs), CubicSplineMethod())
end

function compare_long_range(fs::AbstractVector{<:AbstractFilament}; tol = 1e-8, params_kws...)
    params_exact = @inferred ParamsBiotSavart(;
        params_kws...,
        backend_long = ExactSumBackend(),
    )
    params_default = @inferred ParamsBiotSavart(;
        params_kws...,
        backend_long = FINUFFTBackend(; tol,),
    )

    cache_exact = @inferred(BiotSavart.init_cache(params_exact, fs)).longrange
    cache_default = @inferred(BiotSavart.init_cache(params_default, fs)).longrange

    @test BiotSavart.backend(cache_exact) isa ExactSumBackend
    @test BiotSavart.backend(cache_default) isa FINUFFTBackend

    # Compute induced velocity field in Fourier space
    foreach((cache_exact, cache_default)) do c
        BiotSavart.compute_vorticity_fourier!(c, fs)
        BiotSavart.to_smoothed_velocity!(c)
    end

    # Compare velocities in Fourier space.
    # Note: the comparison is not straightforward since the wavenumbers are not the same.
    # The "exact" implementation takes advantage of Hermitian symmetry to avoid
    # computing half of the data, while FINUFFT doesn't make this possible...
    ks_default = cache_default.common.wavenumbers
    ks_exact = cache_exact.common.wavenumbers
    inds_to_compare = ntuple(Val(3)) do i
        inds = eachindex(ks_exact[i])
        js = i == 1 ? inds[begin:end - 1] : inds
        @assert @views ks_default[i][js] == ks_exact[i][js]  # wavenumbers match in this index region
        js
    end |> CartesianIndices
    diffnorm_L2 = sum(inds_to_compare) do I
        uhat, vhat = cache_exact.common.uhat, cache_default.common.uhat
        du = uhat[I] - vhat[I]
        sum(abs2, du)  # = |u - v|^2
    end
    @test diffnorm_L2 < tol^2

    # Interpolate velocity back to filament positions
    foreach((cache_exact, cache_default)) do c
        BiotSavart.set_interpolation_points!(c, fs)
        BiotSavart.interpolate_to_physical!(c)
    end

    max_rel_error_physical = maximum(zip(cache_exact.common.charges, cache_default.common.charges)) do (qexact, qdefault)
        norm(qexact - qdefault) / norm(qexact)
    end
    @test max_rel_error_physical < tol

    # Copy data to arrays.
    vs_exact = map(f -> zero(nodes(f)), fs)
    vs_default = map(f -> zero(nodes(f)), fs)
    BiotSavart.add_long_range_output!(vs_exact, cache_exact)
    BiotSavart.add_long_range_output!(vs_default, cache_default)

    # Compare velocities one filament at a time.
    @test all(zip(vs_exact, vs_default)) do (u, v)
        isapprox(u, v; rtol = tol)
    end

    nothing
end

function compare_short_range(fs::AbstractVector{<:AbstractFilament}; params_kws...)
    params_naive = @inferred ParamsBiotSavart(;
        params_kws...,
        backend_short = NaiveShortRangeBackend(),
    )
    params_cl = @inferred ParamsBiotSavart(;
        params_kws...,
        backend_short = CellListsBackend(2),
    )

    cache_naive = @inferred(BiotSavart.init_cache(params_naive, fs)).shortrange
    cache_cl = @inferred(BiotSavart.init_cache(params_cl, fs)).shortrange

    BiotSavart.set_filaments!(cache_naive, fs)
    BiotSavart.set_filaments!(cache_cl, fs)

    vs_naive = map(f -> zero(nodes(f)), fs)
    vs_cl = map(f -> zero(nodes(f)), fs)

    for (v, f) ∈ zip(vs_naive, fs)
        BiotSavart.add_short_range_velocity!(v, cache_naive, f)
    end

    for (v, f) ∈ zip(vs_cl, fs)
        BiotSavart.add_short_range_velocity!(v, cache_cl, f)
    end

    for (a, b) ∈ zip(vs_naive, vs_cl)
        @test isapprox(a, b; rtol = 1e-7)
    end

    nothing
end

function compute_filament_velocity(f; α, Ls, params_kws...)
    rcut = min(4 * sqrt(2) / α, minimum(Ls) / 2)
    params = ParamsBiotSavart(; params_kws..., α, Ls, rcut)
    cache = init_cache(params, [f])
    velocity_on_nodes!(similar(nodes(f)), cache, f)
end

# Check that the total induced velocity doesn't depend strongly on the Ewald parameter α.
# (In theory it shouldn't depend at all...)
function check_independence_on_ewald_parameter(f, αs; params_kws...)
    vs_all = map(αs) do α
        compute_filament_velocity(
            f;
            α,
            backend_short = NaiveShortRangeBackend(),
            # Use high-order quadratures to make sure that errors don't come from there.
            quadrature_short = GaussLegendre(6),
            quadrature_long = GaussLegendre(6),
            params_kws...,
        )
    end
    vs_test = last(vs_all)
    maxdiffs = map(vs_all) do vs
        maximum(zip(vs, vs_test)) do (a, b)
            norm(a - b) / norm(b)
        end
    end
    # @show maxdiffs
    @test maximum(maxdiffs) < 1e-4
    nothing
end

@testset "Trefoil" begin
    f = @inferred init_trefoil_filament(30)
    Ls = (1.5π, 1.5π, 2π)  # Ly is small to test periodicity effects
    Ns = (3, 3, 4) .* 16
    kmax = minimum(splat((N, L) -> (N ÷ 2) * 2π / L), zip(Ns, Ls))
    params_kws = (; Ls, Ns, Γ = 2.0, a = 1e-5,)
    @testset "Long range" begin
        compare_long_range([f]; tol = 1e-8, params_kws..., α = kmax / 6)
    end
    @testset "Short range" begin
        compare_short_range([f]; params_kws..., α = kmax / 6)
    end
    @testset "Dependence on α" begin
        αs = [kmax / 5, kmax / 8, kmax / 16]
        check_independence_on_ewald_parameter(f, αs; params_kws...)
    end
end

##

if @isdefined(Makie)
    fig = Figure()
    ax = Axis3(fig[1, 1]; aspect = :data)
    wireframe!(ax, Rect(0, 0, 0, Ls...); color = :grey, linewidth = 0.5)
    plot!(ax, f; refinement = 8)
    fig
end
