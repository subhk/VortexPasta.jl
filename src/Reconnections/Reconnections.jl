"""
    Reconnections

Module for dealing with the reconnection of filaments.
"""
module Reconnections

export ReconnectionCriterion,
       NoReconnections,
       ReconnectBasedOnDistance,
       reconnect!

using ..BasicTypes: Infinity

using ..Filaments: Filaments,
                   AbstractFilament,
                   Segment,
                   Derivative,
                   segments,
                   split!, merge!,
                   update_coefficients!,
                   find_min_distance,
                   deperiodise_separation,
                   check_nodes

using LinearAlgebra: ⋅, norm

include("criteria.jl")
include("cache.jl")

"""
    reconnect_self!(
        cache::ReconnectionCache,
        f::AbstractFilament,
        flist::AbstractVector{<:AbstractFilament};
    ) -> Union{Nothing, AbstractFilament}

Attempt to reconnect filament `f` with itself.

Note that reconnections of a filament with itself produce new filaments.
Newly created filaments will be appended to the `flist` container.

This function returns `nothing` if no reconnection happened.

Otherwise, if a reconnection happened, this function returns one of the
resulting filaments, `f₁`. The other (one or more) resulting filaments are
appended to `flist`.

For example, if the filament `f` self-reconnects onto 4 filaments, this
function returns one of these filaments, and the other 3 are appended to
`flist`. This is useful if one wants to replace the original filament `f` by
one of the resulting filaments.
"""
function reconnect_self!(
        cache::ReconnectionCache, f::F,
        fs_new::AbstractVector{F} = F[];
        istart = firstindex(segments(f)),
    ) where {F <: AbstractFilament}
    crit = criterion(cache)
    crit === NoReconnections() && return nothing  # reconnections are disabled

    d_crit = distance(cache)
    Ls = periods(cache)

    # This cutoff distance serves as a first (coarse) filter.
    # It is larger than the critical distance to take into account the fact
    # that the coarse filter doesn't use the *minimal* distance between
    # segments, but only a rough approximation.
    d_cut = 2 * d_crit
    d_cut_sq = d_cut^2

    inds_i = istart:lastindex(segments(f))
    Ls_half = map(L -> L / 2, Ls)

    # Segments to be "compared" with segment i.
    # We don't want to compare with direct neighbours, since they will often
    # pass the first filter and fail the second one (which is more expensive to compute).
    inds_j = (first(inds_i) + 2):(last(inds_i) - 1)  # avoid indices (i - 1, i, i + 1)

    for i ∈ inds_i
        isempty(inds_j) && break
        x⃗_mid = (f[i] + f[i + 1]) ./ 2
        r⃗_b = let
            y⃗ = f[first(inds_j)]
            deperiodise_separation(y⃗ - x⃗_mid, Ls, Ls_half)
        end
        is_outside_range_b = any(>(d_cut), r⃗_b)  # should be cheaper than computing the squared vector norm
        for j ∈ inds_j
            r⃗_a = r⃗_b
            r⃗_b = let
                y⃗ = f[j + 1]
                deperiodise_separation(y⃗ - x⃗_mid, Ls, Ls_half)
            end
            is_outside_range_a = is_outside_range_b
            is_outside_range_b = any(>(d_cut), r⃗_b)

            if is_outside_range_a && is_outside_range_b
                # Skip this segment if its two limits are too far from x⃗_mid.
                continue
            end

            # Second (slightly finer) filter: look at the actual distances.
            if sum(abs2, r⃗_a) > d_cut_sq || sum(abs2, r⃗_b) > d_cut_sq
                continue
            end

            # The current segment passed the first two filters and is a candidate for reconnection.
            info = should_reconnect(crit, f, f, i, j; periods = Ls)
            info === nothing && continue

            # Split filament into 2
            f₁, f₂ = split!(f, i, j; p⃗ = info.p⃗)

            # Update coefficients and possibly perform reconnections on each subfilament.
            # In the first case, the `istart` is to save some time by skipping
            # segment pairs which were already verified. This requires the
            # nodes in each subfilament to be sorted in a specific manner, and
            # may fail if the split! function is modified.
            if check_nodes(Bool, f₂)  # skip if coefficients can't be computed, typically if the number of nodes is too small (< 3 for cubic splines)
                update_coefficients!(f₂)
                g₂ = reconnect_self!(cache, f₂, fs_new; istart = i + 1)
                push!(fs_new, something(g₂, f₂))  # push f₂, or its replacement if f₂ itself reconnected
            end

            if check_nodes(Bool, f₁)
                update_coefficients!(f₁)
                g₁ = reconnect_self!(cache, f₁, fs_new; istart = firstindex(segments(f₁)))
                return something(g₁, f₁)  # return f₁, or its replacement if f₁ itself reconnected
            end

            return f₁  # we can stop iterating here, since the filament `f` doesn't exist anymore
        end
        inds_j = (i + 3):last(inds_i)  # for next iteration
    end

    nothing
end

"""
    reconnect_other!(
        cache::ReconnectionCache, f::AbstractFilament, g::AbstractFilament,
    ) -> Union{Nothing, AbstractFilament}

Attempt to reconnect filaments `f` and `g`.

The two filaments cannot be the same. To reconnect a filament with itself, see [`reconnect_self!`](@ref).

This function allows at most a single reconnection between the two filaments.
If a reconnection happens, the two filaments merge into one, and the resulting filament is returned.
The original filaments `f` and `g` can be discarded (in particular, `f` is modified internally).

Returns the merged filament a reconnection happened, `nothing` otherwise.
"""
function reconnect_other!(
        cache::ReconnectionCache, f::AbstractFilament, g::AbstractFilament,
    )
    @assert f !== g

    crit = criterion(cache)
    criterion(cache) === NoReconnections() && return nothing  # reconnections are disabled

    d_crit = distance(cache)
    Ls = periods(cache)

    # The following is very similar to `reconnect_self!`
    d_cut = 2 * d_crit
    d_cut_sq = d_cut^2
    Ls_half = map(L -> L / 2, Ls)

    inds_i = eachindex(segments(f))
    inds_j = eachindex(segments(g))

    # TODO reuse Biot-Savart short-range backends
    for i ∈ inds_i
        x⃗_mid = (f[i] + f[i + 1]) ./ 2
        r⃗_b = let
            y⃗ = g[first(inds_j)]
            deperiodise_separation(y⃗ - x⃗_mid, Ls, Ls_half)
        end
        is_outside_range_b = any(>(d_cut), r⃗_b)  # should be cheaper than computing the squared vector norm
        for j ∈ inds_j
            r⃗_a = r⃗_b
            r⃗_b = let
                y⃗ = g[j + 1]
                deperiodise_separation(y⃗ - x⃗_mid, Ls, Ls_half)
            end
            is_outside_range_a = is_outside_range_b
            is_outside_range_b = any(>(d_cut), r⃗_b)

            if is_outside_range_a && is_outside_range_b
                # Skip this segment if its two limits are too far from x⃗_mid.
                continue
            end

            # Second (slightly finer) filter: look at the actual distances.
            if sum(abs2, r⃗_a) > d_cut_sq && sum(abs2, r⃗_b) > d_cut_sq
                continue
            end

            # The current segment passed the first two filters and is a candidate for reconnection.
            info = should_reconnect(crit, f, g, i, j; periods = Ls)
            info === nothing && continue

            h = merge!(f, g, i, j; p⃗ = info.p⃗)  # filaments are merged onto `h`
            update_coefficients!(h)
            return h
        end
    end

    nothing
end

"""
    reconnect!(
        [callback::Function],
        cache::AbstractReconnectionCache,
        fs::AbstractVector{<:AbstractFilament},
    ) -> Int

Perform filament reconnections according to chosen criterion.

Returns the number of performed reconnections.

Note that, when a filament self-reconnects, this creates new filaments, which
are appended at the end of `fs`.

Moreover, this function will remove reconnected filaments if their number of nodes is too small
(typically ``< 3``, see [`check_nodes`](@ref)).

## Callback function

Optionally, one may pass a callback which will be called whenever the vector of
filaments `fs` is modified. Its signature must be the following:

    callback(f::AbstractFilament, i::Int, mode::Symbol)

where `f` is the modified filament, `i` is its index in `fs`, and `mode` is one of:

- `:modified` if the filament `fs[i]` was modified;
- `:appended` if the filament was appended at the end of `fs` (at index `i`);
- `:removed` if the filament previously located at index `i` was removed.

This function calls [`reconnect_other!`](@ref) on all filament pairs, and then
[`reconnect_self!`](@ref) on all filaments.
"""
function reconnect!(
        callback::F,
        cache::AbstractReconnectionCache,
        fs::AbstractVector{<:AbstractFilament},
    ) where {F <: Function}
    number_of_reconnections = 0
    criterion(cache) === NoReconnections() && return number_of_reconnections
    crit = criterion(cache)
    Ls = periods(cache)
    candidates = find_reconnection_candidates!(cache, fs)
    for candidate ∈ candidates
        (; a, b,) = candidate
        # TODO add additional filter?
        info = should_reconnect(crit, a, b; periods = Ls)
        info === nothing && continue
        if a.f === b.f
            # Reconnect filament with itself => split filament into two
            @assert a.i ≠ b.i
            reconnect_with_itself!(callback, fs, a.f, a.i, b.i, info)
            remove_filaments_from_candidates!(cache, a.f)
        else
            # Reconnect two different filaments => merge them into one
            reconnect_with_other!(callback, fs, a.f, b.f, a.i, b.i, info)
            remove_filaments_from_candidates!(cache, a.f, b.f)
        end
        number_of_reconnections += 1
    end
    number_of_reconnections
end

# Find the index of a filament in a vector of filaments.
# Returns `nothing` if the filament is not found.
# This can happen (but should be very rare) if the filament actually disappeared from `fs`
# after a previous reconnection.
find_filament_index(fs, f) = findfirst(g -> g === f, fs)

function reconnect_with_itself!(callback::F, fs, f, i, j, info) where {F}
    n = find_filament_index(fs, f)
    n === nothing && return nothing
    gs = split!(f, i, j; p⃗ = info.p⃗)  # = (g₁, g₂)
    @assert length(gs) == 2

    # Determine whether to keep each new filament.
    # We discard a filament if it can't be represented with the chosen discretisation method
    # (typically if the number of nodes is too small)
    keep = map(g -> check_nodes(Bool, g), gs)
    m = findfirst(keep)  # index of first filament to keep (either 1, 2 or nothing)

    if m === nothing
        # We discard the two filaments and remove the original filament from fs.
        popat!(fs, n)
        callback(f, n, :removed)
        return nothing
    end

    # Replace the original filament by the first accepted filament.
    let g = gs[m]
        update_coefficients!(g)
        fs[n] = g
        callback(g, n, :modified)
    end

    # If the two new filaments were accepted, append the second one at the end of `fs`.
    if count(keep) == 2
        @assert m == 1
        let g = gs[2]
            update_coefficients!(g)
            push!(fs, g)
            callback(g, lastindex(fs), :appended)
        end
    end

    nothing
end

function reconnect_with_other!(callback::F, fs, f, g, i, j, info) where {F}
    @assert f !== g
    nf = find_filament_index(fs, f)
    ng = find_filament_index(fs, g)
    (nf === nothing || ng === nothing) && return nothing  # at least one of the filaments is not present in `fs`

    h = merge!(f, g, i, j; p⃗ = info.p⃗)  # filaments are merged onto `h`
    update_coefficients!(h)

    # Replace `f` by the new filament.
    fs[nf] = h
    callback(h, nf, :modified)

    # Remove `g` from the list of filaments.
    popat!(fs, ng)
    callback(g, ng, :removed)

    nothing
end

function reconnect_old!(
        callback::F,
        cache::AbstractReconnectionCache,
        fs::AbstractVector{<:AbstractFilament},
    ) where {F <: Function}
    number_of_reconnections = 0
    criterion(cache) === NoReconnections() && return number_of_reconnections

    # 1. Reconnect filaments with each other.
    i = firstindex(fs) - 1
    ilast = lastindex(fs)
    while i < ilast
        i += 1
        f = fs[i]
        j = i
        jlast = lastindex(fs)
        while j < jlast
            j += 1
            g = fs[j]
            h = reconnect_other!(cache, f, g)
            h === nothing && continue

            number_of_reconnections += 1

            # The two filaments were merged into `h`, and filaments `f` and `g` can be removed.
            fs[i] = h
            callback(h, i, :modified)
            popat!(fs, j)
            callback(g, j, :removed)
            j -= 1
            jlast -= 1
            ilast -= 1
        end
    end

    # 2. Reconnect filaments with themselves.
    # This needs to be done after reconnecting with each other.
    # In the specific case of two vortices reconnecting at two separate locations, this ensures that:
    #  (i)  In step 1, the two vortices reconnect at one of the locations forming one vortex in step 1.
    #  (ii) In step 2, the "big" vortex generated in step 1 self-reconnects, ending up with two vortices.
    i = firstindex(fs) - 1
    ilast = lastindex(fs)

    while i < ilast  # make sure we don't include appended filaments in the iteration
        i += 1
        f = fs[i]
        n_old = lastindex(fs)

        # If the filament `f` reconnects onto `N` filaments, this will:
        #  1. construct a new filament `f₁`, which should replace `f` in the list of filaments `fs`
        #  2. construct N - 1 additional filaments which will be appended to `fs`
        f₁ = reconnect_self!(cache, f, fs)
        f₁ === nothing && continue  # there were no reconnections

        # First check appended filaments, and remove them if they don't have enough nodes (typically < 3).
        j = n_old
        while j < lastindex(fs)
            # We consider each new filament as a single reconnection.
            number_of_reconnections += 1
            j += 1
            fj = fs[j]  # this is an appended filament
            if check_nodes(Bool, fj)
                callback(fj, j, :appended)
            else
                popat!(fs, j)  # remove the filament
                j -= 1
            end
        end

        # Now replace the old filament `f` by filament `f₁` (which is one of the filaments
        # resulting from the reconnection).
        if check_nodes(Bool, f₁)
            fs[i] = f₁
            callback(f₁, i, :modified)
        else
            popat!(fs, i)
            callback(f₁, i, :removed)
            i -= 1
            ilast -= 1
        end
    end

    number_of_reconnections
end

reconnect!(cache::AbstractReconnectionCache, args...; kws...) =
    reconnect!(Returns(nothing), cache, args...; kws...)

end
