"""
    Filaments

Module for dealing with the discretisation of curves in 3D space.
"""
module Filaments

export
    ClosedFilament,
    ClosedLocalFilament,
    # ClosedSplineFilament,
    Vec3,
    Derivative,
    nodes,
    estimate_derivatives!,
    normalise_derivatives,
    normalise_derivatives!,
    interpolate,
    derivatives,
    derivative

using Base: @propagate_inbounds
using LinearAlgebra: norm, normalize, ⋅, ×
using StaticArrays
using StructArrays

"""
    Vec3{T}

Three-element static vector, alias for `SVector{3, T}`.

Used to describe vectors and coordinates in 3D space.
"""
const Vec3{T} = SVector{3, T}

"""
    Derivative{N}

Represents the ``N``-th order derivative operator.

Used in particular to interpolate derivatives along filaments.
"""
struct Derivative{N} end
Derivative(N::Int) = Derivative{N}()

@doc raw"""
    AbstractFilament{T} <: AbstractVector{Vec3{T}}

Abstract type representing a curve in 3D space.

The curve coordinates are parametrised as ``\bm{X}(t)`` with ``t ∈ ℝ``.

The curve is discretised by a set of *nodes* (or discretisation points)
``\bm{X}(t_i) = \bm{X}_i`` for ``i ∈ \{1, 2, …, N\}``.

See [`ClosedSplineFilament`](@ref) for a concrete implementation of `AbstractFilament`.

An `AbstractFilament` is treated as an `AbstractVector` of length `N`, in which
each element is a discretisation point `\bm{X}_i`. Therefore, one can use the
usual indexing notation to retrieve and to modify discretisation points. See
[`ClosedSplineFilament`](@ref) for some examples.
"""
abstract type AbstractFilament{T} <: AbstractVector{Vec3{T}} end

"""
    ClosedFilament{T} <: AbstractFilament{T}

Abstract type representing a *closed* curve (a loop) in 3D space.
"""
abstract type ClosedFilament{T} <: AbstractFilament{T} end

include("discretisations.jl")

include("local/padded_vector.jl")
include("local/finitediff.jl")
include("local/interpolation.jl")
include("local/interp_hermite.jl")
include("local/closed_filament.jl")

"""
    Filaments.init(ClosedFilament{T}, N::Integer, method::DiscretisationMethod) -> ClosedFilament{T}

Allocate data for a closed filament with `N` discretisation points.

The element type `T` can be omitted, in which case the default `T = Float64` is used.

Depending on the type of `method`, the returned filament may be a
[`ClosedLocalFilament`](@ref) or a [`ClosedSplineFilament`](@ref).
"""
function init end

init(::Type{ClosedFilament}, args...) = init(ClosedFilament{Float64}, args...)

init(::Type{ClosedFilament{T}}, N::Integer, method::LocalDiscretisationMethod) where {T} =
    ClosedLocalFilament(N, method, T)

"""
    estimate_derivatives!(f::AbstractFilament) -> (Ẋs, Ẍs)

Estimate first and second derivatives at filament nodes based on the locations
of the discretisation points.

Note that derivatives are with respect to the (arbitrary) parametrisation
``\\bm{X}(t)``, and *not* with respect to the arclength ``ξ = ξ(t)``. In other
words, the returned derivatives do not directly correspond to the unit tangent
and curvature vectors (but they are closely related).

The estimated derivatives are returned by this function as a tuple of vectors.

The derivatives are stored in the `AbstractFilament` object, and can also be
retrieved later by calling [`derivatives`](@ref) or [`derivative`](@ref).
"""
function estimate_derivatives! end

"""
    normalise_derivatives(Ẋ::Vec3, Ẍ::Vec3) -> (X′, X″)
    normalise_derivatives((Ẋ, Ẍ)::NTuple)   -> (X′, X″)

Return derivatives with respect to the arc length ``ξ``, from derivatives with
respect to the parameter ``t``.

The returned derivatives satisfy:

- ``\\bm{X}' ≡ t̂`` is the **unit tangent** vector;

- ``\\bm{X}'' ≡ ρ n̂`` is the **curvature** vector, where ``n̂`` is the normal unit
  vector (with ``t̂ ⋅ n̂ = 0``) and ``ρ = R^{-1}`` is the curvature (and R the
  curvature radius).
"""
function normalise_derivatives(Ẋ::Vec3, Ẍ::Vec3)
    t̂ = normalize(Ẋ)  # unit tangent vector (= X′)
    X″ = (Ẍ - (Ẍ ⋅ t̂) * t̂) ./ sum(abs2, Ẋ)  # curvature vector
    t̂, X″
end

normalise_derivatives(derivs::NTuple{2, Vec3}) = normalise_derivatives(derivs...)

"""
    normalise_derivatives!(fil::AbstractFilament)
    normalise_derivatives!(Ẋ::AbstractVector, Ẍ::AbstractVector)

Normalise derivatives at filament nodes.

Note that filament derivatives are modified, and thus Hermite interpolations
may be incorrect after doing this. If possible, prefer using
[`normalise_derivatives`](@ref), which works on a single filament location at a time.

See [`normalise_derivatives`](@ref) for more details.
"""
function normalise_derivatives!(Ẋ::AbstractVector, Ẍ::AbstractVector)
    derivs = StructArray((Ẋ, Ẍ))
    map!(normalise_derivatives, derivs, derivs)
    (Ẋ, Ẍ)
end

normalise_derivatives!(fil::AbstractFilament) = normalise_derivatives!(derivatives(fil)...)

end
