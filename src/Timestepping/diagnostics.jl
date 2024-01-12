# Overload diagnostics functions for convenience, so that we can simply pass the current
# state of the solver to get diagnostics.
using ..Diagnostics: Diagnostics

function Diagnostics.kinetic_energy(iter::VortexFilamentSolver; kws...)
    if BiotSavart.domain_is_periodic(iter.prob.p)
        Diagnostics.kinetic_energy_from_streamfunction(iter; kws...)
    else
        Diagnostics.kinetic_energy_nonperiodic(iter; kws...)
    end
end

function Diagnostics.kinetic_energy_from_streamfunction(iter::VortexFilamentSolver; kws...)
    (; ψs, fs, external_forcing, t,) = iter
    Ls = BiotSavart.periods(iter.prob.p)
    BiotSavart.domain_is_periodic(iter.prob.p) ||
        @warn(lazy"`kinetic_energy_from_streamfunction` should only be called when working with periodic domains (got Ls = $Ls)")
    Γ = BiotSavart.circulation(iter.prob.p)
    E = Diagnostics.kinetic_energy_from_streamfunction(ψs, fs, Γ, Ls; kws...)
    # Add kinetic energy of external velocity field, if available.
    # Note that we only do this if we also included the streamfunction, since otherwise
    # we don't have enough information to estimate the total kinetic energy.
    if external_forcing.velocity !== nothing && external_forcing.streamfunction !== nothing
        E += Diagnostics.kinetic_energy_of_periodic_velocity_field(Ls) do x⃗
            external_forcing.velocity(x⃗, t)
        end
    end
    E
end

function Diagnostics.kinetic_energy_nonperiodic(iter::VortexFilamentSolver; kws...)
    (; vs, fs,) = iter
    Ls = BiotSavart.periods(iter.prob.p)
    BiotSavart.domain_is_periodic(iter.prob.p) &&
        @warn(lazy"`kinetic_energy_nonperiodic` should only be called when working with non-periodic domains (got Ls = $Ls)")
    Γ = BiotSavart.circulation(iter.prob.p)
    Diagnostics.kinetic_energy_nonperiodic(vs, fs, Γ; kws...)
end

function Diagnostics.filament_length(iter::VortexFilamentSolver; kws...)
    Diagnostics.filament_length(iter.fs; kws...)
end

function Diagnostics.vortex_impulse(iter::VortexFilamentSolver; kws...)
    Diagnostics.vortex_impulse(iter.fs; kws...)
end

function Diagnostics.energy_spectrum(iter::VortexFilamentSolver; kws...)
    Diagnostics.energy_spectrum(iter.cache_bs; kws...)
end

function Diagnostics.energy_spectrum!(
        Ek::AbstractVector, ks::AbstractVector, iter::VortexFilamentSolver; kws...,
    )
    Diagnostics.energy_spectrum!(Ek, ks, iter.cache_bs; kws...)
end
