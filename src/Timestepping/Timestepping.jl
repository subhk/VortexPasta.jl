"""
    Timestepping

Module defining timestepping solvers for vortex filament simulations.
"""
module Timestepping

export init, solve!, step!, VortexFilamentProblem,
       inject_filament!,
       ShortRangeTerm, LocalTerm,
       ParamsBiotSavart,                           # from ..BiotSavart
       NoReconnections, ReconnectBasedOnDistance,  # from ..Reconnections
       reset_timer!  # from TimerOutputs

using ..Containers: VectorOfVectors

using ..Filaments:
    Filaments,
    AbstractFilament,
    UnitTangent,
    CurvatureVector,
    Vec3,
    nodes,
    segments,
    knots,
    number_type,
    eltype_nested,
    close_filament!,
    filament_length,
    RefinementCriterion,
    NoRefinement

using ..Reconnections:
    Reconnections,
    AbstractReconnectionCache,
    ReconnectionCriterion,
    NoReconnections,
    ReconnectBasedOnDistance,
    reconnect!

using ..BiotSavart:
    BiotSavart,
    ParamsBiotSavart,
    BiotSavartCache,
    VectorOfFilaments,
    VectorOfPositions,
    VectorOfVelocities,
    periods

using ..Forcing: Forcing, AbstractForcing, NormalFluidForcing

# Reuse same init, solve! and step! functions from the SciML ecosystem, to avoid clashes.
# See https://docs.sciml.ai/CommonSolve/stable/
import CommonSolve: init, solve!, step!

using Accessors: @delete  # allows to remove entry from (Named)Tuple
using ForwardDiff: ForwardDiff
using TimerOutputs: TimerOutputs, TimerOutput, @timeit, reset_timer!

abstract type AbstractProblem end
abstract type AbstractSolver end

@enum SimulationStatus begin
    SUCCESS
    NO_VORTICES_LEFT
end

include("timesteppers/timesteppers.jl")
include("adaptivity.jl")
include("problem.jl")
include("simulation_stats.jl")

"""
    TimeInfo

Contains information on the current time and timestep of a solver.

Some useful fields are:

- `t::Float64`: current time;

- `dt::Float64`: timestep to be used in next iteration;

- `dt_prev::Float64` : timestep used in the last performed iteration;

- `nstep::Int`: number of timesteps performed until now;

- `nrejected::Int`: number of rejected iterations.

When using the [`AdaptBasedOnVelocity`](@ref) criterion, an iteration can be rejected if
the actual filament displacement is too large compared to what is imposed by the criterion.
In that case, the iteration will be recomputed with a smaller timestep (`dt → dt/2`).
"""
@kwdef mutable struct TimeInfo
    nstep     :: Int
    nrejected :: Int
    t       :: Float64
    dt      :: Float64
    dt_prev :: Float64
end

function Base.show(io::IO, time::TimeInfo)
    (; nstep, nrejected, t, dt, dt_prev,) = time
    print(io, "TimeInfo:")
    print(io, "\n - nstep     = ", nstep)
    print(io, "\n - t         = ", t)
    print(io, "\n - dt        = ", dt)
    print(io, "\n - dt_prev   = ", dt_prev)
    print(io, "\n - nrejected = ", nrejected)
end

function Base.summary(io::IO, time::TimeInfo)
    (; nstep, nrejected, t, dt, dt_prev,) = time
    print(io, "TimeInfo(nstep = $nstep, t = $t, dt = $dt, dt_prev = $dt_prev, nrejected = $nrejected)")
end

abstract type FastBiotSavartTerm end

"""
    ShortRangeTerm <: FastBiotSavartTerm

Identifies fast dynamics with the **short-range component** of Ewald splitting.

This is only useful for split timestepping schemes like IMEX or multirate methods.
"""
struct ShortRangeTerm <: FastBiotSavartTerm end

"""
    LocalTerm <: FastBiotSavartTerm

Identifies fast dynamics with the **local (LIA) term** associated to the desingularisation
of the Biot–Savart integral.

This is useful for split timestepping schemes like IMEX or multirate methods.
"""
struct LocalTerm <: FastBiotSavartTerm end

"""
    VortexFilamentSolver

Contains the instantaneous state of a vortex filament simulation.

Must be constructed using [`init`](@ref).

# Included fields

Some useful fields included in a `VortexFilamentSolver` are:

- `prob`: associated [`VortexFilamentProblem`](@ref) (including Biot–Savart parameters);

- `fs`: current state of vortex filaments in the system;

- `quantities`: a `NamedTuple` containing data on filament nodes at the current simulation
  timestep. See **Physical quantities** below for more details.

- `time`: a [`TimeInfo`](@ref) object containing information such as the current time and timestep;

- `stats`: a [`SimulationStats`](@ref) object containing information such as the total
  number of reconnections since the beginning of the simulation;

- `to`: a `TimerOutput`, which records the time spent on different functions;

- `cache_bs`: the Biot–Savart cache, which contains data from short- and
  long-range computations.

## Physical quantities

The `quantities` field is a `NamedTuple` containing instantaneous data on filament nodes.
For example, `quantities.vs` is the self-induced vortex velocity. To get the velocity of
filament `i` at node `j`, one can do `quantities.vs[i][j]`. Moreover, these quantities are
often interpolable, which means that one can do `quantities.vs[i](j, 0.5)` to get the
velocity in-between two nodes.

For convenience, if one has a `VortexFilamentSolver` `iter`, the shortcut `iter.vs` is
equivalent to `iter.quantities.vs` (this also applies to all other quantities).

### List of quantities

- `vs`: self-induced vortex velocity (due to Biot–Savart law). If enabled, this also
  includes the contribution of an `external_velocity` (see [`init`](@ref)).

- `ψs`: self-induced streamfunction on vortices. This is useful for estimating the kinetic
  energy associated to the induced velocity field. If enabled, this also includes the
  contribution of an `external_streamfunction` (see [`init`](@ref)).

If a normal fluid is present (e.g. by passing `forcing = NormalFluidForcing(...)` to [`init`](@ref)),
then the following quantities are also available:

- `vL`: actual filament velocity after mutual friction due to normal fluid (see [`NormalFluidForcing`](@ref)).

- `vn`: normal fluid velocity at vortex locations.

- `tangents`: unit tangents ``\\bm{s}'`` at vortex locations.

For convenience, if there is no normal fluid, then `vL` is defined as an alias of `vs`
(they're the same object).

"""
struct VortexFilamentSolver{
        T,
        Problem <: VortexFilamentProblem{T},
        Filaments <: VectorOfVectors{Vec3{T}, <:AbstractFilament{T}},
        Quantities <: NamedTuple,
        Refinement <: RefinementCriterion,
        Adaptivity <: AdaptivityCriterion,
        CacheReconnect <: AbstractReconnectionCache,
        CacheBS <: BiotSavartCache,
        CacheTimestepper <: TemporalSchemeCache,
        FastTerm <: FastBiotSavartTerm,
        Timer <: TimerOutput,
        Affect <: Function,
        Callback <: Function,
        ExternalFields <: NamedTuple,
        StretchingVelocity <: Union{Nothing, Function},
        Forcing <: Union{Nothing, AbstractForcing},
        AdvectFunction <: Function,
        RHSFunction <: Function,
    } <: AbstractSolver
    prob  :: Problem
    fs    :: Filaments
    quantities :: Quantities  # stored fields: (vs, ψs) + optional ones (vn, tangents, ...)
    time  :: TimeInfo
    stats :: SimulationStats{T}
    dtmin :: T
    refinement        :: Refinement
    adaptivity        :: Adaptivity
    reconnect         :: CacheReconnect
    cache_bs          :: CacheBS
    cache_timestepper :: CacheTimestepper
    fast_term         :: FastTerm
    LIA           :: Bool
    fold_periodic :: Bool
    affect!  :: Affect
    callback :: Callback
    external_fields    :: ExternalFields  # velocity and streamfunction forcing
    stretching_velocity :: StretchingVelocity
    forcing  :: Forcing  # typically normal fluid forcing (by mutual friction)
    to       :: Timer
    advect!  :: AdvectFunction  # function for advecting filaments with a known velocity
    rhs!     :: RHSFunction     # function for estimating filament velocities (and sometimes streamfunction) from their positions
end

function Base.show(io_in::IO, iter::VortexFilamentSolver)
    (; quantities,) = iter
    io = IOContext(io_in, :indent => 4)  # this may be used by some `show` functions, for example for the forcing
    print(io, "VortexFilamentSolver with fields:")
    print(io, "\n - `prob`: ", nameof(typeof(iter.prob)))
    _print_summary(io, iter.fs; pre = "\n - `fs`: ", post =  " -- vortex filaments")
    _print_summary(io, quantities.vL; pre = "\n - `quantities.vL`: ", post = " -- vortex line velocity (vs + mutual friction)")
    _print_summary(io, quantities.vs; pre = "\n - `quantities.vs`: ", post = " -- self-induced + external superfluid velocity")
    if haskey(quantities, :vn)
        _print_summary(io, quantities.vn; pre = "\n - `quantities.vn`: ", post = " -- normal fluid velocity")
    end
    if haskey(quantities, :tangents)
        _print_summary(io, quantities.tangents; pre = "\n - `quantities.tangents`: ", post = " -- local unit tangent")
    end
    _print_summary(io, quantities.ψs; pre = "\n - `quantities.ψs`: ", post = " -- streamfunction vector")
    print(io, "\n - `time`: ")
    summary(io, iter.time)
    print(io, "\n - `stats`: ")
    summary(io, iter.stats)
    print(io, "\n - `dtmin`: ", iter.dtmin)
    print(io, "\n - `refinement`: ", iter.refinement)
    print(io, "\n - `adaptivity`: ", iter.adaptivity)
    print(io, "\n - `reconnect`: ", Reconnections.criterion(iter.reconnect))
    print(io, "\n - `fast_term`: ", iter.fast_term)
    print(io, "\n - `LIA`: ", iter.LIA)
    print(io, "\n - `fold_periodic`: ", iter.fold_periodic)
    print(io, "\n - `cache_bs`: ")
    summary(io, iter.cache_bs)
    print(io, "\n - `cache_timestepper`: ")
    summary(io, iter.cache_timestepper)
    print(io, "\n - `affect!`: Function (`", _printable_function(iter.affect!), "`)")
    print(io, "\n - `callback`: Function (`", _printable_function(iter.callback), "`)")
    for (name, func) ∈ pairs(iter.external_fields)
        func === nothing || print(io, "\n - `external_fields.$name`: Function (`$func`)")
    end
    if iter.stretching_velocity !== nothing
        print(io, "\n - `stretching_velocity`: Function (`", iter.stretching_velocity, "`)")
    end
    if iter.forcing !== nothing
        print(io, "\n - `forcing`: ", iter.forcing)
    end
    print(io, "\n - `advect!`: Function")
    print(io, "\n - `rhs!`: Function")
    print(io, "\n - `to`: ")
    summary(io, iter.to)
end

# This is for convenience: allows doing e.g. `iter.t` instead of `iter.time.t` to get the
# current time.
@inline function Base.getproperty(iter::VortexFilamentSolver, name::Symbol)
    time = getfield(iter, :time)
    quantities = getfield(iter, :quantities)
    if hasproperty(time, name)
        getproperty(time, name)
    elseif haskey(quantities, name)
        quantities[name]
    else
        getfield(iter, name)
    end
end

function Base.propertynames(iter::VortexFilamentSolver, private::Bool = false)
    (fieldnames(typeof(iter))..., propertynames(iter.quantities, private)..., propertynames(iter.time, private)...)
end

_printable_function(f::TimerOutputs.InstrumentedFunction) = f.func

get_dt(iter::VortexFilamentSolver) = iter.time.dt
get_t(iter::VortexFilamentSolver) = iter.time.t

@doc raw"""
    init(prob::VortexFilamentProblem, scheme::TemporalScheme; dt::Real, kws...) -> VortexFilamentSolver

Initialise vortex filament problem.

Returns a [`VortexFilamentSolver`](@ref) which can be advanced in time using
either [`step!`](@ref) or [`solve!`](@ref).

# Mandatory positional arguments

- `prob`: a [`VortexFilamentProblem`](@ref) containing the problem definition.

- `scheme`: a timestepping scheme (see [`TemporalScheme`](@ref)).

# Mandatory keyword arguments

- `dt::Real`: the simulation timestep.

# Optional keyword arguments

- `alias_u0 = false`: if `true`, the solver is allowed to modify the initial vortex
  filaments.

- `refinement = NoRefinement()`: criterion used for adaptive refinement of vortex
  filaments. See [`RefinementCriterion`](@ref) for a list of possible criteria.

- `reconnect = NoReconnections()`: criterion used to perform vortex reconnections.
  See [`ReconnectionCriterion`](@ref) for a list of possible criteria.

- `adaptivity = NoAdaptivity()`: criterion used for adaptively setting the timestep `dt`.
  See [`AdaptivityCriterion`](@ref) for a list of possible criteria.

- `dtmin = 0.0`: minimum `dt` for adaptive timestepping. If `dt < dtmin`, the
  solver is stopped with an error.

- `fast_term = LocalTerm()`: for IMEX and multirate schemes, this determines what is meant by
  "fast" and "slow" dynamics. This can either be [`LocalTerm`](@ref) or [`ShortRangeTerm`](@ref).

- `LIA = false`: if `true`, only use the local induction approximation (LIA) to advance
  vortex filaments, ignoring all non-local interactions. Note that reconnections may still
  be enabled.

- `fold_periodic = true`: if `true` (default), vortices will be recentred onto the main unit cell
  when using periodic boundary conditions. It may be convenient to disable this for
  visualisation purposes. This setting doesn't affect the results (velocity of each
  filament, reconnections, …), besides possible spatial translations of the filaments
  proportional to the domain period.

- `callback`: a function to be called at the end of each timestep. The function
  must accept a single argument `iter::VortexFilamentSolver`. **Filaments should not be
  modified** by this function. In that case use `affect!` instead. See notes below for more
  details.

- `affect!`: similar to `callback`, but allows to modify filament definitions. See notes
  below for more details.

- `timer = TimerOutput("VortexFilament")`: an optional `TimerOutput` for
  recording the time spent on different functions.

- `external_velocity` / `external_streamfunction`: allows to add an external velocity field to
  "force" the filaments. See "Adding an external velocity" below for more details.

- `stretching_velocity`: allows to add an external "stretching" velocity to the filaments.
  This can be considered as an external energy (or length) injection mechanism.
  However, it can also lead to spurious Kelvin waves.
  See "Adding a stretching velocity" below for more details.

- `forcing`: allows to modify the vortex velocities due to mutual friction with an imposed
  normal fluid velocity field. See "Forcing via a normal fluid" below for more details.

# Extended help

## Difference between `callback` and `affect!`

The difference between the `callback(iter)` and `affect!(iter)` functions is the time at
which they are called:

- the `affect!` function is called *before* performing Biot-Savart computations from the
  latest filament positions. In other words, the fields in `iter.quantities` are not
  synchronised with `iter.fs`, and it generally makes no sense to access them.
  Things like energy estimates will be incorrect if done in `affect!`. On the other hand,
  the `affect!` function **allows to modify `iter.fs`** before Biot–Savart computations are
  performed. In particular, to inject new filaments, call [`inject_filament!`](@ref) from
  within the `affect!` function.

- the `callback` function is called *after* performing Biot-Savart computations.
  This means that the fields in `iter.quantities` have been computed from the latest filament positions.
  However, one **must not modify `iter.fs`**, or otherwise the velocity `iter.vs` (which
  will be used at the next timestep) will no longer correspond to the filament positions.

## Forcing / energy injection methods

There are multiple implemented methods for affecting and injecting energy onto the vortex system.
These methods can represent different physical mechanisms (or in fact be quite unphysical), and some
of them can make more sense than others when simulating e.g. zero-temperature superfluids.

### Adding an external velocity

One can set the **`external_velocity`** keyword argument to impose an external velocity field
``\bm{v}_{\text{f}}(\bm{x}, t)``.
In this case, the total velocity at a point ``\bm{x}`` (which can be on a vortex filament) will be

```math
\bm{v}(\bm{x}) = \bm{v}_{\text{BS}}(\bm{x}) + \bm{v}_{\text{f}}(\bm{x})
```

where ``\bm{v}_{\text{BS}}`` is the velocity obtained from the Biot–Savart law.

This can be a way of applying an external forcing (and injecting energy) to the vortex system.

The external velocity should be given as a function, which should have the signature `v_ext(x⃗::Vec3, t::Real) -> Vec3`.
The function should return a `Vec3` with the velocity at the location `x⃗` and time `t`.
For example, to impose a constant sinusoidal forcing in the ``x`` direction which varies along ``z``,
the `external_velocity` keyword argument could look like:

    external_velocity = (x⃗, t) -> Vec3(0.1 * sin(2 * x⃗.z), 0, 0)

One usually wants the external velocity to be divergence-free, to preserve the
incompressibility of the flow.

#### Notes on energy estimation

When setting an external velocity ``\bm{v}_{\text{f}}(\bm{x}, t)``, one may also want to
impose an external streamfunction field ``\bm{ψ}_{\text{f}}(\bm{x}, t)`` via the **`external_streamfunction`**
keyword argument.
Such a field plays no role in the dynamics, but it allows to include the kinetic energy
associated to the external velocity field when calling [`Diagnostics.kinetic_energy_from_streamfunction`](@ref).
If provided, the external streamfunction should satisfy ``\bm{v}_{\text{f}} = \bm{∇} × \bm{ψ}_{\text{f}}``.

More precisely, when applying an external velocity field, the total kinetic energy is

```math
\begin{align*}
    E &= \frac{1}{2V} ∫ |\bm{v}_{\text{BS}} + \bm{v}_{\text{f}}|^2 \, \mathrm{d}^3\bm{x}
    \\
    &= \frac{1}{2V} \left[
    Γ ∮_{\mathcal{C}} \left( \bm{ψ}_{\text{BS}} + 2 \bm{ψ}_{\text{f}} \right) ⋅ \mathrm{d}\bm{s}
    +
    ∫ |\bm{v}_{\text{f}}|^2 \, \mathrm{d}^3\bm{x}
    \right],
\end{align*}
```

where ``\bm{ψ}_{\text{BS}}`` is the streamfunction obtained from the Biot-Savart law.
Accordingly, when passing `external_streamfunction`, the streamfunction values attached to
vortex filaments (in `iter.ψs`) will actually contain
``\bm{ψ}_{\text{BS}} + 2 \bm{ψ}_{\text{f}}`` (note the factor 2) to enable the
computation of the full kinetic energy.
Moreover, calling [`Diagnostics.kinetic_energy_from_streamfunction`](@ref) with a
[`VortexFilamentSolver`](@ref) will automatically include an estimation of the kinetic
energy of the external velocity field (the volume integral above).

!!! note

    Whether this total kinetic energy is of any physical interest is a different question,
    so it can be reasonable to ignore the `external_streamfunction` parameter in order to
    obtain the energy associated to ``\bm{v}_{\text{BS}}`` only.

### Adding a stretching velocity

One can set the **`stretching_velocity`** keyword argument to impose a stretching velocity
``\bm{v}_\text{L}(ξ, t)`` on filament locations ``\bm{s}(ξ, t)``.
This velocity will be parallel (and generally opposite) to the curvature vector
``\bm{s}'' = ρ \bm{N}``, where ``ρ`` is the curvature and ``\bm{N}`` the unit normal.

More precisely, the `stretching_velocity` parameter allows to set a filament velocity of the
form

```math
\bm{v}_{\text{L}}(ξ) = -v_{\text{L}}[ρ(ξ)] \, \bm{N}(ξ)
```

where ``v_{\text{L}}`` is a velocity magnitude which can optionally depend on the local
curvature value ``ρ``.
The `stretching_velocity` parameter should therefore be a function `v(ρ::Real) -> Real`.

Note that ``\bm{v} ⋅ \bm{s}''`` can be roughly interpreted as a local stretching rate
(this is actually true for the integrated quantity, see [`Diagnostics.stretching_rate`](@ref)).
Therefore, one may want ``v_{\text{L}}`` to be inversely proportional to the local
curvature ``ρ``, so that the local stretching rate is approximately independent of the
filament location ``ξ``.
To achieve this, one may set

```julia
stretching_velocity = ρ -> min(γ / ρ, v_max)
```

where `γ` is a constant (units ``T^{-1}``) setting the stretching magnitude, and `v_max` is
a maximum stretching velocity used to avoid very large velocities in low-curvature regions.
One could do something fancier and replace the `min` with a smooth regularisation such as

```julia
stretching_velocity = ρ -> -expm1(-ρ / ρ₀) * (γ / ρ)  # note: expm1(x) = exp(x) - 1
```

for some small curvature ``ρ₀``. The maximum allowed velocity will then be `vmax = γ / ρ₀`.

### Forcing via a normal fluid

Alternatively to the above approaches, one may impose a "normal" fluid velocity field to
modify, via a mutual friction force, the velocity of the vortex filaments. To do this, one
first needs to construct a [`NormalFluidForcing`](@ref) (see that link for definitions and examples)
representing a normal fluid velocity field. Then, the obtained object should be passed as
the optional `forcing` argument.

In principle, this method can be combined with the previous ones. The normal fluid forcing
will be applied _after_ all the other forcing methods.
In other words, the vortex velocity ``\bm{v}_{\text{s}}`` used to compute the mutual
friction velocity includes all the other contributions (i.e. external and stretching velocities).

### Injecting filaments over time

Another way of injecting energy is simply by adding vortices to the simulation from time to
time. This can be achieved by using an `affect!` function. See [`inject_filament!`](@ref) for
some more details.
"""
function init(
        prob::VortexFilamentProblem{T}, scheme::TemporalScheme;
        alias_u0 = false,   # same as in OrdinaryDiffEq.jl
        dt::Real,
        dtmin::Real = 0.0,
        fast_term::FastBiotSavartTerm = LocalTerm(),
        refinement::RefinementCriterion = NoRefinement(),
        reconnect::ReconnectionCriterion = NoReconnections(),
        adaptivity::AdaptivityCriterion = NoAdaptivity(),
        fold_periodic::Bool = true,
        LIA::Bool = false,
        callback::Callback = identity,
        affect!::Affect = identity,
        external_velocity::ExtVel = nothing,
        external_streamfunction::ExtStf = nothing,
        stretching_velocity::StretchingVelocity = nothing,
        forcing::Forcing = nothing,
        timer = TimerOutput("VortexFilament"),
    ) where {
        Callback <: Function,
        Affect <: Function,
        ExtVel <: Union{Nothing, Function},
        ExtStf <: Union{Nothing, Function},
        StretchingVelocity <: Union{Nothing, Function},
        Forcing <: Union{Nothing, AbstractForcing},
        T,
    }
    (; tspan,) = prob
    (; Ls,) = prob.p
    fs = convert(VectorOfVectors, prob.fs)

    # Describe the velocity and streamfunction on filament locations using the
    # ClosedFilament type, so that we can interpolate these fields on filaments.
    # For now we don't require any derivatives.
    vs = map(fs) do f
        Filaments.similar_filament(f; nderivs = Val(0), offset = zero(eltype(f)))
    end :: VectorOfVectors
    ψs = similar(vs)

    quantities = if with_normal_fluid(forcing)
        (; vs, ψs, vL = similar(vs), vn = similar(vs), tangents = similar(vs),)
    else
        (; vs, ψs, vL = vs,)  # vL is an alias to vs
    end

    fs_sol = alias_u0 ? fs : copy(fs)

    cache_reconnect = Reconnections.init_cache(reconnect, fs_sol, Ls)
    cache_bs = BiotSavart.init_cache(prob.p, fs_sol; timer)
    cache_timestepper = init_cache(scheme, fs, vs)

    # Wrap functions with the timer, so that timings are estimated each time the function is called.
    advect! = timer(advect_filaments!, "Advect filaments")
    rhs! = timer(update_values_at_nodes!, "Update values at nodes")
    callback_ = timer(callback, "Callback")
    affect_ = timer(affect!, "Affect!")

    adaptivity_ = possibly_add_max_timestep(adaptivity, dt)
    if adaptivity_ !== NoAdaptivity() && !can_change_dt(scheme)
        throw(ArgumentError(lazy"temporal scheme $scheme doesn't support adaptibility; set `adaptivity = NoAdaptivity()` or choose a different scheme"))
    end

    # It doesn't make much sense to combine the LIA and fast_term arguments, since there's
    # no RHS splitting to do when using LIA.
    # Therefore, if LIA is enabled, we only support the default fast_term = LocalTerm().
    if LIA && fast_term !== LocalTerm()
        throw(ArgumentError("currently, using LIA requires setting fast_term = LocalTerm()"))
    end

    time = TimeInfo(nstep = 0, nrejected = 0, t = first(tspan), dt = dt, dt_prev = dt)
    stats = SimulationStats(T)

    external_fields = (
        velocity = external_velocity,
        streamfunction = external_streamfunction,
    )
    check_external_streamfunction(external_fields, Ls)

    if stretching_velocity !== nothing
        # Check that the function accepts a real value of type T (local curvature) and
        # returns a real value (velocity magnitude).
        stretching_velocity(one(T))::Real
    end

    iter = VortexFilamentSolver(
        prob, fs_sol, quantities, time, stats, T(dtmin), refinement, adaptivity_, cache_reconnect,
        cache_bs, cache_timestepper, fast_term, LIA, fold_periodic, affect_, callback_, external_fields,
        stretching_velocity, forcing,
        timer, advect!, rhs!,
    )

    status = finalise_step!(iter)
    status == SUCCESS || error("reached status = $status at initialisation")

    iter
end

# For now, there is a normal fluid only if the forcing argument is a NormalFluidForcing.
with_normal_fluid(forcing::NormalFluidForcing) = true
with_normal_fluid(forcing) = false

with_normal_fluid(iter::VortexFilamentSolver) = :vn ∈ keys(iter.quantities)

function fields_to_resize(iter::VortexFilamentSolver)
    (; quantities,) = iter
    if with_normal_fluid(iter)
        values(quantities)  # resize all fields
    else
        @assert quantities.vs === quantities.vL  # they're aliased
        values(@delete quantities.vL)  # resize all fields except vL (aliased with vs)
    end
end

function fields_to_interpolate(iter::VortexFilamentSolver)
    (; quantities,) = iter
    if with_normal_fluid(iter)
        values(quantities)  # interpolate all fields (not sure we need all of them...)
    else
        @assert quantities.vs === quantities.vL  # they're aliased
        values(@delete quantities.vL)  # interpolate all fields except vL (aliased with vs)
    end
end

# Check that the external streamfunction satisfies v = ∇ × ψ on a single arbitrary point.
# We check this using automatic differentiation of ψ at a given point.
function check_external_streamfunction(forcing::NamedTuple, Ls)
    (; velocity, streamfunction,) = forcing
    (velocity === nothing || streamfunction === nothing) && return nothing
    N = length(Ls)
    x⃗ = Vec3(ntuple(i -> 0.07 * i * Ls[i], Val(N)))  # arbitrary point in [0, L]³
    t = 0.0  # arbitrary time
    v⃗_actual = velocity(x⃗, t)
    v⃗_from_streamfunction = Filaments.curl(y⃗ -> streamfunction(y⃗, t), x⃗)
    isapprox(v⃗_actual, v⃗_from_streamfunction) || @warn(
        """
        it seems like the external streamfunction doesn't match the external velocity.
        This may cause wrong energy estimates.
        """,
        v⃗_actual, v⃗_from_streamfunction,
    )
    nothing
end

# This variant computes the full BS law + any added velocities.
function _update_values_at_nodes!(
        ::Val{:full},
        ::FastBiotSavartTerm,  # ignored in this case
        fields::NamedTuple{Names, NTuple{N, V}},
        fs::VectorOfFilaments,
        t::Real,
        iter::VortexFilamentSolver,
    ) where {Names, N, V <: VectorOfVectors}
    if iter.LIA
        BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs; LIA = Val(:only))
    else
        BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs)
    end
    add_external_fields!(fields, iter, fs, t, iter.to)
    apply_forcing!(fields, iter, fs, t, iter.to)
end

# Compute slow component only.
# This is generally called in IMEX-RK substeps, where only the velocity (and not the
# streamfunction) is needed.
# We assume that the "slow" component is everything but LIA term when evolving the
# Biot-Savart law.
# This component will be treated explicitly by IMEX schemes.
function _update_values_at_nodes!(
        ::Val{:slow},
        ::LocalTerm,
        fields::NamedTuple{(:velocity,)},
        fs::VectorOfFilaments,
        t::Real,
        iter::VortexFilamentSolver,
    )
    T = eltype_nested(Vec3, fields.velocity)
    @assert T <: Vec3
    if iter.LIA
        fill!(fields.velocity, zero(T))
    else
        BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs; LIA = Val(false))
    end
    nothing
end

function _update_values_at_nodes!(
        ::Val{:slow},
        ::ShortRangeTerm,
        fields::NamedTuple{(:velocity,)},
        fs::VectorOfFilaments,
        t::Real,
        iter::VortexFilamentSolver,
    )
    BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs; shortrange = false)
end

# Compute fast component only.
# This is generally called in IMEX-RK substeps, where only the velocity (and not the
# streamfunction) is needed.
# We assume that the "fast" component is the LIA term when evolving the Biot-Savart law.
# This component will be treated implicitly by IMEX schemes.
function _update_values_at_nodes!(
        ::Val{:fast},
        ::LocalTerm,
        fields::NamedTuple{(:velocity,)},
        fs::VectorOfFilaments,
        t::Real,
        iter::VortexFilamentSolver,
    )
    BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs; LIA = Val(:only))
    add_external_fields!(fields, iter, fs, t, iter.to)
    apply_forcing!(fields, iter, fs, t, iter.to)
end

function _update_values_at_nodes!(
        ::Val{:fast},
        ::ShortRangeTerm,
        fields::NamedTuple{(:velocity,)},
        fs::VectorOfFilaments,
        t::Real,
        iter::VortexFilamentSolver,
    )
    BiotSavart.compute_on_nodes!(fields, iter.cache_bs, fs; longrange = false)
    add_external_fields!(fields, iter, fs, t, iter.to)
    apply_forcing!(fields, iter, fs, t, iter.to)
end

# This is the most general variant which should be called by timesteppers.
function update_values_at_nodes!(
        fields::NamedTuple, fs, t::Real, iter;
        component = Val(:full),  # compute slow + fast components by default
    )
    _update_values_at_nodes!(component, iter.fast_term, fields, fs, t, iter)
end

# Case where only the velocity is passed (generally used in internal RK substeps).
function update_values_at_nodes!(vL::VectorOfVectors, args...; kws...)
    fields = (velocity = vL,)
    update_values_at_nodes!(fields, args...; kws...)
    vL
end

# Here buf is usually a VectorOfFilaments or a vector of vectors of velocities
# (containing the velocities of all filaments).
# Resizes the higher-level vector without resizing the individual vectors it contains.
function resize_container!(buf, fs::VectorOfFilaments)
    i = lastindex(buf)
    N = lastindex(fs)
    i === N && return buf
    while i < N
        i += 1
        push!(buf, similar(first(buf), length(fs[i])))
    end
    while i > N
        i -= 1
        pop!(buf)
    end
    @assert length(fs) == length(buf)
    buf
end

function resize_contained_vectors!(buf, fs::VectorOfFilaments)
    for (i, f) ∈ pairs(fs)
        N = length(f)
        resize!(buf[i], N)
    end
    buf
end

function refine!(f::AbstractFilament, refinement::RefinementCriterion)
    nref = Filaments.refine!(f, refinement)  # we assume update_coefficients! was already called
    n = 0
    nmax = 1  # maximum number of extra refinement iterations (to avoid infinite loop...)
    while nref !== (0, 0) && n < nmax
        n += 1
        @debug "Added/removed $nref nodes"
        if !Filaments.check_nodes(Bool, f)
            # This may happen if the refinement removed nodes, and now the number of nodes
            # is too small (usually < 3) to represent the filament.
            # It doesn't make sense to keep refining the filament (and it will fail
            # anyways).
            # The filament will be removed in finalise_step!.
            break
        end
        nref = Filaments.refine!(f, refinement)
    end
    n
end

# Variant called in RK substeps
function _advect_filament!(f::T, fbase::T, vL, dt) where {T <: AbstractFilament}
    Xs = nodes(f)
    Ys = nodes(fbase)
    for i ∈ eachindex(Xs, Ys, vL)
        @inbounds Xs[i] = Ys[i] + dt * vL[i]
    end
    # Compute interpolation coefficients making sure that knots are preserved (and not
    # recomputed from new locations).
    Filaments.update_coefficients!(f; knots = knots(fbase))
    nothing
end

# Variant called to really advect filaments from one timestep to the next
function _advect_filament!(
        f::AbstractFilament, fbase::Nothing, vL::VectorOfVelocities, dt::Real,
    )
    Xs = nodes(f)
    for i ∈ eachindex(Xs, vL)
        @inbounds Xs[i] = Xs[i] + dt * vL[i]
    end
    Filaments.update_coefficients!(f)  # note: in this case we recompute the knots
    nothing
end

function after_advection!(iter::VortexFilamentSolver)
    (; fs, prob, refinement, fold_periodic, stats, to,) = iter
    # Perform reconnections, possibly changing the number of filaments.
    @timeit to "reconnect!" rec = reconnect!(iter)
    @debug lazy"Number of reconnections: $(rec.reconnection_count)"
    stats.reconnection_count += rec.reconnection_count
    stats.reconnection_length_loss += rec.reconnection_length_loss
    stats.filaments_removed_count += rec.filaments_removed_count
    stats.filaments_removed_length += rec.filaments_removed_length
    L_fold = periods(prob.p)  # box size (periodicity)
    fields = fields_to_resize(iter)
    after_advection!(fs, fields; L_fold, refinement, fold_periodic,)
end

# This should be called right after positions have been updated by the timestepper.
# Here `fields` is a tuple containing the fields associated to each filament node.
# Usually this is `(vs, ψs)`, which contain the velocities and streamfunction values at all
# filament nodes.
function after_advection!(fs, fields::Tuple; kws...)
    @inbounds for i ∈ eachindex(fs)
        fields_i = map(vs -> @inbounds(vs[i]), fields)  # typically this is (vs[i], ψs[i])
        _after_advection!(fs[i], fields_i; kws...)
    end
    fs
end

function _after_advection!(f::AbstractFilament, fields::Tuple; L_fold, refinement, fold_periodic,)
    if fold_periodic && Filaments.fold_periodic!(f, L_fold)
        Filaments.update_coefficients!(f)  # only called if nodes were modified by fold_periodic!
    end
    refinement_steps = refine!(f, refinement)
    if refinement_steps > 0  # refinement was performed
        map(vs -> resize!(vs, length(f)), fields)
    end
    f
end

# The possible values of fbase are:
# - `nothing` (default), used when the filaments `fs` should be actually advected with the
#   chosen velocity at the end of a timestep;
# - some list of filaments similar to `fs`, used to advect from `fbase` to `fs` with the
#   chosen velocity. This is generally done from within RK stages, and in this case things
#   like filament refinement are not performed.
advect_filaments!(fs, vL, dt; fbase = nothing, kws...) =
    _advect_filaments!(fs, fbase, vL, dt; kws...)

# Variant called at the end of a timestep.
function _advect_filaments!(fs, fbase::Nothing, vL, dt)
    for i ∈ eachindex(fs, vL)
        @inbounds _advect_filament!(fs[i], nothing, vL[i], dt)
    end
    fs
end

# Variant called from within RK stages.
function _advect_filaments!(fs::T, fbase::T, vL, dt) where {T}
    for i ∈ eachindex(fs, fbase, vL)
        @inbounds _advect_filament!(fs[i], fbase[i], vL[i], dt)
    end
    fs
end

"""
    solve!(iter::VortexFilamentSolver)

Advance vortex filament solver to the ending time.

See also [`step!`](@ref) for advancing one step at a time.
"""
function solve!(iter::VortexFilamentSolver)
    (; time,) = iter
    t_end = iter.prob.tspan[2]
    while time.t < t_end
        if can_change_dt(iter.cache_timestepper)
            # Try to finish exactly at t = t_end.
            time.dt = min(time.dt, t_end - time.t)
        end
        status = step!(iter)
        if status != SUCCESS
            @warn lazy"reached status = $status. Stopping the simulation."
            break
        end
    end
    iter
end

# Returns the maximum |v⃗| from a VectorOfVectors.
# We mainly use it to get the maximum velocity norm among all filament nodes.
function maximum_vector_norm(vs::VectorOfVectors{<:Vec3})
    T = number_type(vs)
    @assert T <: AbstractFloat
    v²_max = zero(T)
    for vnodes ∈ vs, v⃗ ∈ vnodes
        v²_max = max(v²_max, sum(abs2, v⃗)::T)
    end
    sqrt(v²_max)
end

"""
    step!(iter::VortexFilamentSolver) -> SimulationStatus

Advance solver by a single timestep.

Returns a `SimulationStatus`. Currently, this can be:

- `SUCCESS`,
- `NO_VORTICES_LEFT`: all vortices have been removed from the system; the simulation should
  be stopped.
"""
function step!(iter::VortexFilamentSolver{T}) where {T}
    (; fs, quantities, time, adaptivity, dtmin, advect!, rhs!,) = iter
    (; ψs, vL,) = quantities
    vL_start = ψs  # reuse ψs to store velocity at start of timestep (needed by RK schemes)
    copyto!(vL_start, vL)
    t_end = iter.prob.tspan[2]
    if time.dt < dtmin && time.t + time.dt < t_end
        error(lazy"current timestep is too small ($(time.dt) < $(dtmin)). Stopping.")
    end

    # Maximum allowed displacement in a single timestep (can be Inf).
    δ_crit::T = maximum_displacement(adaptivity)

    while true
        # Note: the timesteppers assume that vL already contains the filament velocities
        # computed at the start of the current timestep.
        update_velocities!(vL, rhs!, advect!, iter.cache_timestepper, iter)  # timestepping

        # Compute actual maximum displacement.
        v_max = maximum_vector_norm(vL)::T
        δ_max = v_max * T(time.dt)

        if δ_max > δ_crit
            # Reject velocities and reduce timestep by half.
            time.nrejected += 1
            time.dt /= 2
            copyto!(vL, vL_start)  # reset velocities to the beginning of timestep
        else
            break
        end
    end

    advect!(fs, vL, time.dt)
    after_advection!(iter)
    time.t += time.dt
    time.nstep += 1
    status = finalise_step!(iter)

    status
end

# Here fields is usually (vs, ψs, vL, ...)
@inline function reconnect_callback((fs, fields), f, i, mode::Symbol)
    if mode === :removed
        @debug lazy"Filament was removed at index $i"
        # @assert i ≤ lastindex(fields[1]) == lastindex(fs) + 1
        map(vs -> popat!(vs, i), fields)
    elseif mode === :appended
        @debug lazy"Filament was appended at index $i"
        @assert f === fs[i]
        # @assert i == lastindex(fields[1]) + 1
        map(vs -> push!(vs, similar(first(vs), length(f))), fields)
    elseif mode === :modified
        @debug lazy"Filament was modified at index $i"
        @assert f === fs[i]
        # @assert i ≤ lastindex(fs) == lastindex(fields[1])
        map(vs -> resize!(vs[i], length(f)), fields)
    end
    nothing
end

function Reconnections.reconnect!(iter::VortexFilamentSolver)
    # Here vL is the velocity that was used to perform the latest filament displacements (in advect!).
    (; vL, fs, reconnect, to,) = iter
    fields = fields_to_resize(iter)
    Reconnections.reconnect!(reconnect, fs, vL; to) do f, i, mode
        reconnect_callback((fs, fields), f, i, mode)
    end
end

# Called whenever filament positions have just been initialised or updated.
# Returns a SimulationStatus.
function finalise_step!(iter::VortexFilamentSolver)
    (; fs, time, stats, adaptivity, rhs!,) = iter
    (; vs, vL, ψs,) = iter.quantities

    @assert eachindex(fs) == eachindex(vL) == eachindex(vs)

    # Check if there are filaments to be removed (typically with ≤ 3 discretisation points,
    # but this depends on the actual discretisation method). Note that filaments may also
    # be removed during reconnections for the same reason.
    for i ∈ reverse(eachindex(fs))
        f = fs[i]
        if !Filaments.check_nodes(Bool, f)
            # Remove filament and its associated vectors of velocities/streamfunctions.
            @debug lazy"Removing filament with $(length(f)) nodes"
            # Compute vortex length using the straight segment approximation (no quadratures),
            # since the filament doesn't accept a continuous description at this point.
            Filaments.close_filament!(f)  # needed before calling filament_length
            local Lfil = filament_length(f; quad = nothing)
            stats.filaments_removed_count += 1
            stats.filaments_removed_length += Lfil
            popat!(fs, i)
            for field ∈ fields_to_resize(iter)
                popat!(field, i)
            end
        end
    end

    isempty(fs) && return NO_VORTICES_LEFT

    iter.affect!(iter)

    # Update velocities and streamfunctions to the next timestep (and first RK step).
    # Note that we only compute the streamfunction at full steps, and not in the middle of
    # RK substeps.
    # TODO: make computation of ψ optional?
    fields = (velocity = vL, streamfunction = ψs,)

    # Note: here we always include the LIA terms, even when using IMEX or multirate schemes.
    # This must be taken into account by scheme implementations.
    rhs!(fields, fs, time.t, iter; component = Val(:full))

    # Update coefficients in case we need to interpolate fields, e.g. for diagnostics or
    # reconnections. We make sure we use the same parametrisation (knots) of the filaments
    # themselves.
    # TODO: perform reconnections after this?
    for i ∈ eachindex(fs)
        local ts = Filaments.knots(fs[i])
        foreach(fields_to_interpolate(iter)) do qs
            Filaments.update_coefficients!(qs[i]; knots = ts)
        end
    end

    time.dt_prev = time.dt
    time.dt = estimate_timestep(adaptivity, iter)  # estimate dt for next timestep
    iter.callback(iter)

    SUCCESS
end

"""
    inject_filament!(iter::VortexFilamentSolver, f::AbstractFilament)

Inject a filament onto a simulation.

This function **must** be called from within the `affect!` function attached to the solver
(see [`init`](@ref) for details). Otherwise, the solver will likely use garbage values for
the velocity of the injected filament, leading to wrong results or worse.

# Basic usage

A very simplified (and incomplete) example of how to inject filaments during a simulation:

```julia
# Define function that will be called after each simulation timestep
function my_affect!(iter::VortexFilamentSolver)
    f = Filaments.init(...)  # create new filament
    inject_filament!(iter, f)
    return nothing
end

# Initialise and run simulation
prob = VortexFilamentProblem(...)
iter = init(prob, RK4(); affect! = my_affect!, etc...)
solve!(iter)
```
"""
function inject_filament!(iter::VortexFilamentSolver, f::AbstractFilament)
    (; fs,) = iter
    # 1. Add filament to list of filaments
    push!(fs, f)
    # 2. Add space to store values on filaments (velocities, etc.)
    for us ∈ fields_to_resize(iter)
        @assert !isempty(us)
        u_new = similar(first(us), length(f))
        push!(us, u_new)
    end
    nothing
end

include("forcing.jl")
include("diagnostics.jl")

end

