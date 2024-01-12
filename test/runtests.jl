using Test

# Wraps each test file in a separate module, to avoid definition clashes and to make sure
# that each file can also be run as a standalone script.
macro includetest(path::String)
    modname = Symbol("Mod_" * replace(path, '.' => '_'))
    escname = esc(modname)
    ex = quote
        @info "Running $($path)"
        module $escname
            $escname.include($path)
        end
        using .$modname
    end
    ex.head = :toplevel
    ex
end

@info "Running tests with $(Threads.nthreads()) threads"

@testset "VortexPasta.jl" begin
    @includetest "vector_of_vector.jl"
    @includetest "padded_arrays.jl"
    @includetest "splines.jl"
    @includetest "filaments.jl"
    @includetest "refinement.jl"
    @includetest "hdf5.jl"
    @includetest "ring.jl"
    @includetest "ring_energy.jl"
    @includetest "ring_perturbed.jl"
    @includetest "ring_collision.jl"
    @includetest "trefoil.jl"
    @includetest "infinite_lines.jl"
    @includetest "imex.jl"
    @includetest "leapfrogging.jl"
    @includetest "kelvin_waves.jl"
    @includetest "forced_lines.jl"
    @includetest "min_distance.jl"
    @includetest "reconnections.jl"
    @includetest "plots.jl"
end
