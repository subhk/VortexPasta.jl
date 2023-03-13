export
    HermiteInterpolation

"""
    HermiteInterpolation{M} <: InterpolationMethod

Hermite interpolation of continuity ``C^M`` at interpolation points.

Hermite interpolations are obtained using curve derivatives up to order ``M``.

## Allowed cases

- for ``M = 0`` this is simply linear interpolation (note that curvatures
  cannot be estimated from linear interpolations);

- for ``M = 1`` this is the standard Hermite interpolation (piecewise cubic
  polynomials, requires first derivatives at interpolation points);

- for ``M = 2`` this is a quintic Hermite interpolation requiring first and
  second derivatives at interpolation points.
"""
struct HermiteInterpolation{M} <: InterpolationMethod end

HermiteInterpolation(M::Int) = HermiteInterpolation{M}()

Base.show(io::IO, ::HermiteInterpolation{M}) where {M} =
    print(io, "HermiteInterpolation(", M, ")")

# Linear interpolation
# Coordinates and derivatives are expected to be normalised so that t ∈ [0, 1]
function interpolate(
        ::HermiteInterpolation{0}, ::Derivative{N},
        t::Number, Xs::NTuple{2}, etc...,
    ) where {N}
    N::Int
    if N === 0
        (1 - t) * Xs[1] + t * Xs[2]
    elseif N === 1
        Xs[2] - Xs[1]
    elseif N ≥ 2
        zero(Xs[1])
    else
        nothing
    end
end

# Cubic Hermite interpolation
function interpolate(
        ::HermiteInterpolation{1}, ::Derivative{N},
        t::Number, Xs::NTuple{2}, Xs′::NTuple{2}, etc...,
    ) where {N}
    N::Int
    if N === 0
        t2 = t * t
        t3 = t2 * t
        (
            (2 * t3 - 3 * t2 + 1) * Xs[1]
            +
            (-2 * t3 + 3 * t2) * Xs[2]
            +
            (t3 - 2 * t2 + t) * Xs′[1]
            +
            (t3 - t2) * Xs′[2]
        )
    elseif N === 1
        t2 = t * t
        (
            (6 * t2 - 6 * t) * Xs[1]
            +
            (-6 * t2 + 6 * t) * Xs[2]
            +
            (3 * t2 - 4 * t + 1) * Xs′[1]
            +
            (3 * t2 - 2t) * Xs′[2]
        )
    elseif N === 2
        (
            (12 * t - 6) * Xs[1]
            +
            (-12 * t + 6) * Xs[2]
            +
            (6 * t - 4) * Xs′[1]
            +
            (6 * t - 2) * Xs′[2]
        )
    else
        nothing
    end
end

# Quintic Hermite interpolation
@inline function interpolate(
        ::HermiteInterpolation{2}, ::Derivative{0},
        t::Number, Xs::NTuple{2}, Xs′::NTuple{2}, Xs″::NTuple{2}, etc...,
    )
    t2 = t * t
    t3 = t2 * t
    t4 = t2 * t2
    t5 = t2 * t3
    (
        (1 - 10t3 + 15t4 - 6t5) * Xs[1]
        +
        (10t3 - 15t4 + 6t5) * Xs[2]
        +
        (t - 6t3 + 8t4 - 3t5) * Xs′[1]
        +
        (-4t3 + 7t4 - 3t5) * Xs′[2]
        +
        (t2 - 3t3 + 3t4 - t5) / 2 * Xs″[1]
        +
        (t3 - 2t4 + t5) / 2 * Xs″[2]
    )
end

@inline function interpolate(
        ::HermiteInterpolation{2}, ::Derivative{1},
        t::Number, Xs::NTuple{2}, Xs′::NTuple{2}, Xs″::NTuple{2}, etc...,
    )
    t2 = t * t
    t3 = t2 * t
    t4 = t2 * t2
    (
        30 * (-t2 + 2t3 - t4) * Xs[1]
        +
        30 * (t2 - 2t3 + t4) * Xs[2]
        +
        (1 - 18t2 + 32t3 - 15t4) * Xs′[1]
        +
        (-12t2 + 28t3 - 15t4) * Xs′[2]
        +
        (2t - 9t2 + 12t3 - 5t4) / 2 * Xs″[1]
        +
        (3t2 - 8t3 + 5t4) / 2 * Xs″[2]
    )
end

@inline function interpolate(
        ::HermiteInterpolation{2}, ::Derivative{2},
        t::Number, Xs::NTuple{2}, Xs′::NTuple{2}, Xs″::NTuple{2}, etc...,
    )
    t2 = t * t
    t3 = t2 * t
    (
        (-60t + 180t2 - 120t3) * Xs[1]
        +
        (60t - 180t2 + 120t3) * Xs[2]
        +
        (-36t + 96t2 - 60t3) * Xs′[1]
        +
        (-24t + 84t2 - 60t3) * Xs′[2]
        +
        (2 - 18t + 36t2 - 20t3) / 2 * Xs″[1]
        +
        (6t - 24t2 + 20t3) / 2 * Xs″[2]
    )
end
