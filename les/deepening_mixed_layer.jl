using Oceananigans, Random, Printf, JLD2

# Set `makeplot=true` to enable plotting.
makeplot = false

macro withplots(ex)
    makeplot ? :($(esc(ex))) : :(nothing)
end

@withplots using PyPlot

# 
# Model set-up
#

# Two cases from Van Roekel et al (JAMES, 2018)
parameters = Dict(:free_convection => Dict(:Qb=>3.39e-8, :Qu=>0.0,     :f=>1e-4, :N²=>1.96e-5),
                  :wind_stress     => Dict(:Qb=>0.0,     :Qu=>9.66e-5, :f=>0.0,  :N²=>9.81e-5))

# Simulation parameters
case = :wind_stress
Nx = 128
Nz = 128             # Resolution    
Lx = Lz = 128        # Domain extent
Δx = 3              # Grid spacing
Δz = 0.5            # Grid spacing
tf = 8day            # Final simulation time

N², Qb, Qu, f = (parameters[case][p] for p in (:N², :Qb, :Qu, :f))
αθ, g = 2e-4, 9.81
Qθ, dθdz = Qb / (g*αθ), N² / (g*αθ)

# Create boundary conditions.
ubcs = HorizontallyPeriodicBCs(top=BoundaryCondition(Flux, Qu))
θbcs = HorizontallyPeriodicBCs(top=BoundaryCondition(Flux, Qθ), 
                               bottom=BoundaryCondition(Gradient, dθdz))

# Instantiate the model
model = Model(      arch = HAVE_CUDA ? GPU() : CPU(), 
                       N = (Nx, Nx, Nz), 
                       L = (Lx, Lx, Lz),
                     eos = LinearEquationOfState(βT=αθ, βS=0.0),
               constants = PlanetaryConstants(f=f, g=g),
                 closure = VerstappenAnisotropicMinimumDissipation(),
                     bcs = BoundaryConditions(u=ubcs, T=θbcs))

# Set initial condition. Initial velocity and salinity fluctuations needed for AMD.
Ξ(z) = randn() * z / model.grid.Lz * (1 + z / model.grid.Lz) # noise
θᵢ(x, y, z) = 20 + dθdz * z + dθdz * model.grid.Lz * 1e-6 * Ξ(z)
uᵢ(x, y, z) = 1e-4 * Ξ(z)

set!(model, u=uᵢ, v=uᵢ, T=θᵢ, S=uᵢ)

#
# Set up output
#

function init_bcs(file, model)
    file["boundary_conditions/top/Qb"] = Qb
    file["boundary_conditions/top/Qu"] = Qu
    file["boundary_conditions/bottom/N²"] = N²
    return nothing
end

u(model) = Array(model.velocities.u.data.parent)
v(model) = Array(model.velocities.v.data.parent)
w(model) = Array(model.velocities.w.data.parent)
T(model) = Array(model.tracers.T.data.parent)
νₑ(model) = Array(model.diffusivities.νₑ.data.parent)
κₑ(model) = Array(model.diffusivities.κₑ.T.data.parent)

fields = Dict(:u=>u, :v=>v, :w=>w, :T=>T, :ν=>νₑ, :κ=>κₑ)
filename = @sprintf("%s_Nx%d_Nz%d_verstappen%.1f", case, Nx, Nz, model.closure.C)
field_writer = JLD2OutputWriter(model, fields; dir="data", init=init_bcs, prefix=filename, 
                                interval=6hour, force=true)
push!(model.output_writers, field_writer)

# 
# Run the simulation
#

@withplots fig, axs = subplots()

function terse_message(model, walltime, Δt)
    wmax = maximum(abs, model.velocities.w.data.parent)
    cfl = Δt / Oceananigans.cell_advection_timescale(model)
    return @sprintf("i: %d, t: %.4f hours, Δt: %.3f s, wmax: %.6f ms⁻¹, cfl: %.3f, wall time: %s\n",
                    model.clock.iteration, model.clock.time/3600, Δt, wmax, cfl, prettytime(1e9*walltime))
end

# A wizard for managing the simulation time-step.
wizard = TimeStepWizard(cfl=0.2, Δt=0.05, max_change=1.1, max_Δt=90.0)

w²_filename = @sprintf("data/vertical_velocity_variance_%s_Nx%d_Nz%d.jld2", case, Nx, Nz)
max_w², t = [], []
include("velocity_variance_utils.jl")

# Spin up
for i = 1:100
    update_Δt!(wizard, model)
    walltime = Base.@elapsed step_with_w²!(max_w², t, model, wizard.Δt, 10)
    @printf "%s" terse_message(model, walltime, wizard.Δt)
end

# Run the model
while model.clock.time < tf
    update_Δt!(wizard, model)
    walltime = Base.@elapsed step_with_w²!(max_w², t, model, wizard.Δt, 100)
    @printf "%s" terse_message(model, walltime, wizard.Δt)

    rm(w²_filename, force=true)
    @save w²_filename max_w² t
    
    @withplots begin
        sca(axs); cla()
        imshow(rotr90(view(data(model.velocities.w), :, 2, :)))
        gcf(); pause(0.01)
    end
end