module VortexPasta

include("PaddedArrays/PaddedArrays.jl")  # completely independent of other modules
include("PredefinedCurves/PredefinedCurves.jl")  # completely independent of other modules

include("CellLists/CellLists.jl")        # requires PaddedArrays only

include("BasicTypes/BasicTypes.jl")

include("Quadratures/Quadratures.jl")
using .Quadratures
export GaussLegendre

include("Filaments/Filaments.jl")
include("FilamentIO/FilamentIO.jl")
include("Reconnections/Reconnections.jl")

include("BiotSavart/BiotSavart.jl")
include("Diagnostics/Diagnostics.jl")

include("Timestepping/Timestepping.jl")

## Precompilation
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    using .PredefinedCurves
    using .Filaments
    using .BiotSavart
    using .Timestepping
    using .Diagnostics

    ## Set-up a vortex filament simulation
    # Grid-related parameters
    Ls = (1, 1, 1) .* 2π
    Ns = (1, 1, 1) .* 32
    kmax = minimum(splat((N, L) -> (N ÷ 2) * 2π / L), zip(Ns, Ls))
    α = kmax / 5
    rcut = 4 * sqrt(2) / α

    # Physical vortex parameters
    Γ = 1.2
    a = 1e-6
    Δ = 1/4  # full core

    function callback(iter)
        E = Diagnostics.kinetic_energy_from_streamfunction(iter)
        nothing
    end

    @compile_workload begin
        params_bs = ParamsBiotSavart(;
            Γ, a, Δ,
            α, rcut, Ls, Ns,
            backend_short = CellListsBackend(2),
            backend_long = FINUFFTBackend(nthreads = 1),
            quadrature_short = GaussLegendre(4),
            quadrature_long = GaussLegendre(4),
        )

        # Initialise vortex ring
        S = define_curve(Ring(); scale = π / 3)
        f = Filaments.init(S, ClosedFilament, 32, CubicSplineMethod())
        fs = [f]
        l_min = minimum_knot_increment(fs)

        # Initialise and run simulation
        tspan = (0.0, 0.01)
        prob = VortexFilamentProblem(fs, tspan, params_bs)
        iter = init(
            prob, RK4();
            dt = 0.001,
            adaptivity = AdaptBasedOnSegmentLength(1.0),
            refinement = RefineBasedOnSegmentLength(0.75 * l_min),
            callback,
        )
        solve!(iter)
    end
end

end
