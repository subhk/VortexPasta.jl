using LinearAlgebra: normalize, norm

using ..BasicTypes: ∞

@doc raw"""
    from_vector_field(
        ClosedFilament, vecfield::Function, s⃗₀, dτ, method::DiscretisationMethod;
        max_steps = 1000,
    ) -> ClosedFilament

Initialise closed filament from vector field.

Here `vecfield` is a function ``\bm{ω}(\bm{x})`` which takes a 3D vector `x⃗` and returns a
vector value `⃗ω⃗`.
A filament will be created such that, for each point ``\bm{s}`` on the filament, the tangent
vector ``\bm{s}'`` is parallel to the vector field at that point, ``\bm{ω}(\bm{s})``.
The field should be such that lines constructed this way are closed.

A possible application of this function is for constructing a filament which approximates
**vortex lines** from a vorticity field, which are precisely defined in this way.

One may use [`Filaments.distance_to_field`](@ref) to verify the result of this function.

## Positional arguments

- `vecfield::Function`: function taking a 3D coordinate `x⃗` and returning a vector value `ω⃗`;

- `s⃗₀::Vec3`: location where to start iterating.
   This point is guaranteed to be in the generated filament;

- `dτ::Real`: approximately distance between filament nodes. It should be small enough so
  that the discretised lines are properly closed (see below for details);

- `method::DiscretisationMethod`: discretisation method to use (e.g. [`CubicSplineMethod()`](@ref CubicSplineMethod)).

## Optional keyword arguments

- `max_steps::Int = 1000`: maximum number of steps before we stop iterating. This is also
  the maximum possible length of the returned filament;

- `nsubsteps::Int = 1`: number of solver substeps to perform for each spatial increment `dτ`.
  Larger values may be used to improve accuracy;

- `redistribute = true`: if `true` (default), [`redistribute_nodes!`](@ref) is called at the end
  to make sure that nodes are approximately distributed in a uniform way along the filament.

# Extended help

The filament is generated by numerically solving the ODE:

```math
\frac{\mathrm{d}\bm{s}(τ)}{\mathrm{d}τ} = \hat{\bm{ω}}(\bm{s}), \quad \bm{s}(0) = \bm{s}_0,
```

where ``τ`` denotes a "pseudo-time" (which actually has units of a length) and
``\hat{\bm{ω}} = \bm{ω} / |\bm{ω}|`` is a unitary vector aligned with the vector field.
The ODE is solved numerically using a standard 4th order Runge–Kutta scheme.

In this context, the ``dτ`` argument is actually the "timestep" used when solving this ODE.
It must be small enough so that the curve is accurately tracked.

Note that the curve will be automatically closed (and the ODE stopped) if we reach an
``\bm{s}(τ)`` which is sufficiently close (closer than ``dτ/2``) to the starting point
``\bm{s}_0``.
If that never happens, we stop after we have performed `max_steps` solver iterations.
"""
function from_vector_field(
        ::Type{ClosedFilament}, vecfield::F, s⃗₀::Vec3, dτ, method::DiscretisationMethod;
        redistribute = true, kws...,
    ) where {F <: Function}
    xs = [s⃗₀]
    offset = _from_vector_field!(vecfield, xs, dτ; kws...)
    f = Filaments.init(ClosedFilament, xs, method; offset)
    if redistribute
        redistribute_nodes!(f)
    else
        update_coefficients!(f)
    end
    f
end

function _from_vector_field!(
        vecfield::F, xs, dτ;
        nsubsteps = 1,
        max_steps = 1000,
        periods = nothing,  # domain period (used to decide whether to close the curve)
    ) where {F <: Function}
    f(x) = normalize(vecfield(x))
    xinit = first(xs)
    Ls = periods === nothing ? ntuple(_ -> ∞, Val(length(xinit))) : periods
    Lhs = map(L -> L / 2, Ls)  # half periods
    r²_crit = (dτ / 2)^2  # squared end-to-end critical distance to stop iterating
    r²_prev = zero(eltype(xinit))
    r²_pprev = r²_prev
    dt_solver = dτ / nsubsteps
    for _ ∈ 2:max_steps
        xnew = last(xs)
        # Note: the resulting "velocity" is not exactly unitary but usually very close to
        # it. We normalise it just in case.
        for _ ∈ 1:nsubsteps
            v = advancement_velocity_RK4(f, xnew, dt_solver)
            xnew = xnew + normalize(v) * dt_solver
        end
        r⃗ = xnew - xinit
        r⃗ₚ = deperiodise_separation(r⃗, Ls, Lhs)
        r² = sum(abs2, r⃗ₚ)
        # Stop if the point (n - 1) is closer to the starting point than both the points
        # (n - 2) and n. Note that we discard the point n.
        if r²_prev < min(r², r²_pprev, r²_crit)
            break
        end
        r²_prev, r²_pprev = r², r²_prev
        push!(xs, xnew)
    end
    length(xs) == max_steps &&
        @warn "Reached maximum number of steps. The curve may not be properly closed." max_steps dτ nsubsteps
    p⃗ = xs[end] - xinit  # should be roughly a multiple of the period
    if periods === nothing
        offset = zero(p⃗)
    else
        ps = round.(Int, p⃗ ./ Ls)
        offset = ps .* periods
    end
    # Reposition the last point to avoid curve weirdness (for example, having to go
    # "backwards" to close the curve).
    xlast = xinit + offset
    xs[end] = (xs[end - 1] + xlast) / 2
    offset
end

# Obtain "velocity" of advancement using standard RK4 scheme.
function advancement_velocity_RK4(f::F, xbase, dt) where {F}
    v1 = f(xbase)
    v2 = f(xbase + v1 * dt/2)
    v3 = f(xbase + v2 * dt/2)
    v4 = f(xbase + v3 * dt)
    (v1 + 2v2 + 2v3 + v4) ./ 6
end

"""
    Filaments.distance_to_field(vecfield::Function, f::AbstractFilament) -> Real

Return an estimate of the normalised "distance" between a filament and a target vector field.

This function is meant to be used to verify the result of [`Filaments.from_vector_field`](@ref),
more specifically to verify that the filament is everywhere tangent to the objective vector
field.

Returns 0 if the filament is perfectly tangent to the vector field at all discretisation
points.

See [`Filaments.from_vector_field`](@ref) for more details.
"""
function distance_to_field(vecfield::F, f::AbstractFilament) where {F}
    T = eltype(eltype(f))  # e.g. Float64
    res::T = zero(T)
    L::T = zero(T)  # estimated total line length
    ts = knots(f)
    @inbounds for i ∈ eachindex(f)
        s⃗ = f[i]
        s⃗′ = f[i, Derivative(1)]
        dt = (ts[i + 1] - ts[i - 1]) / 2
        ω⃗ = vecfield(s⃗)
        uv = s⃗′ ⋅ ω⃗
        uu = sum(abs2, s⃗′)  # units: [L²T⁻²] where T is the parametrisation unit
        vv = sum(abs2, ω⃗)
        # This is basically the squared Gram–Schmidt projection.
        # It is 0 if both vectors are perfectly aligned.
        err² = uu - uv^2 / vv   # units: [L²T⁻²]
        err² = max(err², zero(err²))  # avoid tiny negative values
        res += sqrt(err²) * dt  # units: [L] (length)
        L += norm(s⃗′) * dt
    end
    res / L  # normalise by the estimated total line length
end
