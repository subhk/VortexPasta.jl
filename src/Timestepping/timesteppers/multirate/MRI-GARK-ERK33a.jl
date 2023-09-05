export SanduMRI33a

"""
    SanduMRI33a([inner = Midpoint()], M::Int) <: MultirateScheme

3rd order, 3-stage multirate infinitesimal, generalised additive Runge–Kutta (MRI-GARK) scheme.

Uses the explicit RK scheme `inner` for the fast component (by default a 2nd order midpoint
scheme), with `M` inner steps for each outer RK stage.

This is the MRI-GARK-ERK33a method from Sandu, SIAM J. Numer. Anal. 57 (2019).
"""
struct SanduMRI33a{InnerScheme <: ExplicitScheme} <: MultirateScheme
    inner     :: InnerScheme
    nsubsteps :: Int
end

SanduMRI33a(M::Integer) = SanduMRI33a(Midpoint(), M)

nstages(::SanduMRI33a) = 3
inner_scheme(scheme::SanduMRI33a) = scheme.inner

nbuf_filaments(scheme::SanduMRI33a) = 1 + nbuf_filaments(inner_scheme(scheme))
nbuf_velocities(scheme::SanduMRI33a) = nstages(scheme) + nbuf_velocities(inner_scheme(scheme))

function _update_velocities!(
        scheme::SanduMRI33a, rhs!::F, advect!::G, cache, iter::AbstractSolver,
    ) where {F <: Function, G <: Function}
    (; fs, vs,) = iter
    (; fc, vc,) = cache

    t = get_t(iter)
    dt = get_dt(iter)

    s = nstages(scheme)
    ftmp = fc[1]
    vS = ntuple(j -> vc[j], Val(s))  # slow velocity at each stage

    cache_inner = let scheme = inner_scheme(scheme)
        TemporalSchemeCache(
            scheme,
            ntuple(j -> fc[1 + j], Val(nbuf_filaments(scheme))),
            ntuple(j -> vc[s + j], Val(nbuf_velocities(scheme))),
        )
    end

    tsub = t
    Mfast = scheme.nsubsteps
    cdt = dt / s
    hfast = cdt / Mfast  # timestep for evolution of fast component

    # Compute slow component at beginning of step
    rhs!(vS[1], fs, t, iter; component = Val(:fast))
    @. vS[1] = vs - vS[1]  # slow component at stage 1
    copy!(ftmp, fs)        # initial condition for stage 1

    # Always advect from latest filament positions in `ftmp`.
    fbase = ftmp

    # Coupling coefficients (divided by Δc = 1/3)
    δ = -0.5
    Γ₀ = 3 * SMatrix{3, 3}(
        1/3, (-6δ - 7)/12, 0,          # column 1
        0, (6δ + 11)/12, (6δ - 5)/12,  # column 2
        0, 0, (3 - 2δ)/4,              # column 3
    )
    Γ₁ = 3 * SMatrix{3, 3}(
        0, (2δ + 1)/2, 1/2,
        0, -(2δ + 1)/2, 0,
        0, 0, δ,
    )
    Γs = (Γ₀, Γ₁)

    ts = (t, t + cdt, t + 2cdt, t + dt)

    # Stage 1. Note that the "slow" velocity is constant throughout this stage (we don't
    # need to introduce the normalised time τ).
    let i = 1
        # Solve auxiliary ODE in [t, t + dt/3].
        @assert tsub ≈ ts[i]
        function rhs_inner!(vs, fs, t, iter)
            rhs!(vs, fs, t, iter; component = Val(:fast))  # compute fast component
            @. vs = vs + vS[1]  # add slow component
        end
        for m ∈ 1:Mfast
            rhs_inner!(vs, ftmp, tsub, iter)
            update_velocities!(
                rhs_inner!, advect!, cache_inner, iter;
                resize_cache = false, t = tsub, dt = hfast, fs = ftmp, vs = vs,
            )
            advect!(ftmp, vs, hfast; fbase)
            tsub += hfast
        end

        # Compute slow velocity at next stage
        rhs!(vS[i + 1], ftmp, tsub, iter; component = Val(:slow))
    end

    # Stage 2
    let i = 2
        # Solve auxiliary ODE in [t + (i - 1) * dt/s, t + i * dt/s].
        @assert tsub ≈ ts[i]
        vslow = ntuple(j -> vS[j], Val(i))
        function rhs_inner!(vs, fs, t, iter)
            rhs!(vs, fs, t, iter; component = Val(:fast))
            τ = (t - ts[i]) / cdt  # normalised time in [0, 1]
            _MRI_inner_add_forcing_term!(vs, vslow, Γs, τ)
        end
        for m ∈ 1:Mfast
            rhs_inner!(vs, ftmp, tsub, iter)
            update_velocities!(
                rhs_inner!, advect!, cache_inner, iter;
                resize_cache = false, t = tsub, dt = hfast, fs = ftmp, vs = vs,
            )
            advect!(ftmp, vs, hfast; fbase)
            tsub += hfast
        end

        # Compute slow velocity at next stage
        rhs!(vS[i + 1], ftmp, tsub, iter; component = Val(:slow))
    end

    # Stage 3
    let i = 3
        # Solve auxiliary ODE in [t + (i - 1) * dt/s, t + i * dt/s].
        @assert tsub ≈ ts[i]
        vslow = ntuple(j -> vS[j], Val(i))
        function rhs_inner!(vs, fs, t, iter)
            rhs!(vs, fs, t, iter; component = Val(:fast))
            τ = (t - ts[i]) / cdt  # normalised time in [0, 1]
            _MRI_inner_add_forcing_term!(vs, vslow, Γs, τ)
        end
        for m ∈ 1:Mfast
            rhs_inner!(vs, ftmp, tsub, iter)
            update_velocities!(
                rhs_inner!, advect!, cache_inner, iter;
                resize_cache = false, t = tsub, dt = hfast, fs = ftmp, vs = vs,
            )
            advect!(ftmp, vs, hfast; fbase)
            tsub += hfast
        end
    end

    @assert tsub ≈ ts[4]

    # Now ftmp is at the final position. We compute the effective velocity to go from fs to
    # ftmp (for consistency with other schemes).
    for i ∈ eachindex(fs, ftmp, vs)
        @. vs[i] = (ftmp[i] - fs[i]) / dt
    end

    vs
end
