export NoRefinement,
       RefineBasedOnCurvature,
       RefineBasedOnSegmentLength

using LinearAlgebra: norm
using StaticArrays: SVector

"""
    RefinementCriterion

Abstract type describing a curve refinement criterion.

Implemented refinement criteria are:

- [`NoRefinement`](@ref): disables refinement;

- [`RefineBasedOnSegmentLength`](@ref): enforces a minimum and maximum distance between
  neighbouring filament nodes;

- [`RefineBasedOnCurvature`](@ref): inserts more nodes on highly-curved filament segments.
"""
abstract type RefinementCriterion end

"""
    refine!(f::AbstractFilament, crit::RefinementCriterion) -> (Int, Int)

Refine the filament according to a given criterion.

By default, it also removes nodes

Returns the number of added and removed nodes.

Example usage:

    crit = RefineBasedOnCurvature(0.5)
    refine!(f, crit)

"""
function refine! end

struct RefinementCache
    inds   :: Vector{Int}   # indices of nodes or segments to modify
    remove :: Vector{Bool}  # determine whether nodes should be removed or segments should be refined
    RefinementCache() = new(Int[], Bool[])
end

function Base.empty!(c::RefinementCache)
    empty!(c.inds)
    empty!(c.remove)
    c
end

"""
    NoRefinement <: RefinementCriterion
    NoRefinement()

Used to disable filament refinement.
"""
struct NoRefinement <: RefinementCriterion end

@inline Base.getproperty(crit::NoRefinement, name::Symbol) = _getproperty(crit, Val(name))

# Return a fake cache.
function _getproperty(::NoRefinement, ::Val{:cache})
    inds = SVector{0, Int}()
    remove = SVector{0, Float64}()
    (; inds, remove,)
end

_nodes_to_refine!(::AbstractFilament, crit::NoRefinement) = crit.cache

"""
    RefineBasedOnCurvature <: RefinementCriterion
    RefineBasedOnCurvature(ρℓ_max::Real, ρℓ_min = ρℓ_max / 2.5; ℓ_max = Inf)

Curvature-based refinement criterion.

## Node insertion

According to this criterion, a filament is locally refined if:

```math
ρ \\left|\\bm{X}_{i + 1} - \\bm{X}_{i}\\right| > (ρℓ)_{\\max}
```

where ``ρ`` is some estimation of the curvature of segment ``[i, i + 1]``.

For splines, this uses a classical knot insertion algorithm which preserves the
shape of the curve.

## Node removal

Similarly, filaments nodes are removed based on the value of `ρℓ_min`.
This value should be less than `ρℓ_max / 2` to avoid alternatively adding and
removing nodes when repeatedly calling [`refine!`](@ref).

For safety, two adjacent nodes will never be removed in a single call to `refine!`.

Note that, when filaments are nearly straight, this may lead to the removal of most nodes.
To limit this, set the keyword argument `ℓ_max` to some finite value
determining the maximum length of a segment.
This setting will be roughly respected when removing nodes.
"""
struct RefineBasedOnCurvature <: RefinementCriterion
    ρℓ_max :: Float64
    ρℓ_min :: Float64
    ℓ_max  :: Float64
    ℓ_min  :: Float64
    cache  :: RefinementCache
    RefineBasedOnCurvature(ρℓ_max, ρℓ_min; ℓ_max = Inf, ℓ_min = 0.0) =
        new(ρℓ_max, ρℓ_min, ℓ_max, ℓ_min, RefinementCache())
end

RefineBasedOnCurvature(ρℓ_max; kws...) = RefineBasedOnCurvature(ρℓ_max, ρℓ_max / 2.5; kws...)

function _nodes_to_refine!(f::AbstractFilament, crit::RefineBasedOnCurvature)
    (; ρℓ_max, ρℓ_min, ℓ_max, ℓ_min, cache,) = crit
    (; inds, remove,) = cache
    ts = knots(f)
    empty!(cache)
    skipnext = false
    iter = eachindex(segments(f))  # iterate over segments of the unmodified filament
    for i ∈ iter
        if skipnext
            skipnext = false
            continue
        end
        ℓ = ts[i + 1] - ts[i]  # assumes parametrisation corresponds to node distance
        # ℓ = norm(f[i + 1] - f[i])
        ρ = (f[i, CurvatureScalar()] + f[i + 1, CurvatureScalar()]) / 2
        # ρ_alt = f(i, 0.5, CurvatureScalar())  # this is likely more expensive, and less accurate for FiniteDiff
        ρℓ = ρ * ℓ
        if ρℓ > ρℓ_max && ℓ > 2 * ℓ_min  # so that the new ℓ is roughly larger than ℓ_min
            @debug lazy"Inserting node at t = $((ts[i] + ts[i + 1]) / 2)"
            push!(inds, i)
            push!(remove, false)
        elseif ρℓ < ρℓ_min && ℓ < ℓ_max / 2  # so that the new ℓ is roughly smaller than ℓ_max
            @debug lazy"Removing node at t = $(ts[i + 1])"
            push!(inds, i + 1)
            push!(remove, true)
            skipnext = true
        end
    end
    cache
end

"""
    RefineBasedOnSegmentLength <: RefinementCriterion
    RefineBasedOnSegmentLength(ℓ_min, ℓ_max = 2 * ℓ_min)

Refinement criterion imposing a minimum segment length.

This refinement criterion imposes neighbouring filament nodes to be at a distance
``ℓ ∈ [ℓ_{\\min}, ℓ_{\\max}]``. This means that:

- nodes are **inserted** if the distance between two nodes is ``ℓ > ℓ_{\\max}``.
  The insertion is done at an intermediate position using the functional representation of
  the filament (e.g. splines or Hermite interpolation);

- nodes are **removed** if the distance between two nodes is ``ℓ < ℓ_{\\min}``.
  For a filament which is strongly curved at that point, this means that local information
  is lost and that the filament is smoothed.
"""
struct RefineBasedOnSegmentLength <: RefinementCriterion
    ℓ_min :: Float64
    ℓ_max :: Float64
    cache :: RefinementCache
    function RefineBasedOnSegmentLength(ℓ_min, ℓ_max = 2 * ℓ_min)
        ℓ_min < ℓ_max || error(lazy"ℓ_min should be smaller than ℓ_max (got ℓ_max/ℓ_min = $ℓ_max/$ℓ_min)")
        new(ℓ_min, ℓ_max, RefinementCache())
    end
end

function _nodes_to_refine!(f::AbstractFilament, crit::RefineBasedOnSegmentLength)
    (; ℓ_max, ℓ_min, cache,) = crit
    (; inds, remove,) = cache
    ts = knots(f)
    empty!(cache)
    skipnext = false
    iter = eachindex(segments(f))  # iterate over segments of the unmodified filament
    for i ∈ iter
        if skipnext
            skipnext = false
            continue
        end
        ℓ = ts[i + 1] - ts[i]  # assumes parametrisation corresponds to node distance
        # ℓ = norm(f[i + 1] - f[i])
        if ℓ > ℓ_max
            @debug lazy"Inserting node at t = $((ts[i] + ts[i + 1]) / 2)"
            push!(inds, i)
            push!(remove, false)
        elseif ℓ < ℓ_min
            @debug lazy"Removing node at t = $(ts[i + 1])"
            push!(inds, i + 1)
            push!(remove, true)
            skipnext = true
        end
    end
    cache
end
