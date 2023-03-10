# Version 0.1.0

module GNCTestServer
import Base: *, +
using LinearAlgebra
using MsgPack
using Printf
using SatelliteDynamics
using Sockets
include("quaternions.jl")
include("mag_field.jl")

export simulator, Control, Parameters 

*(v::NamedTuple, s::Number) = map(y -> s * y, v)
*(s::Number, v::NamedTuple) = map(y -> s * y, v)
+(a::NamedTuple, b::NamedTuple) = map(+, a, b)

const State = NamedTuple{
    (:r, :v, :q, :ω),
    Tuple{Array{Float64,1},
        Array{Float64,1},
        Array{Float64,1},
        Array{Float64,1}}
}

mutable struct Parameters
    J::Array{Float64,2} # Inertia matrix
    b::Array{Float64,1} # Magnetic field
end

mutable struct Control
    m::Array{Float64,1} # Control input
end

MAGIC_PACKET_SIZE = 43

"""
Rung-Kutta 4th order integrator
"""
function rk4(x, t, dt, derivative)
    k₁ = dt * derivative(x, t)
    k₂ = dt * derivative(x + k₁ * 0.5, t + dt * 0.5)
    k₃ = dt * derivative(x + k₂ * 0.5, t + dt * 0.5)
    k₄ = dt * derivative(x + k₃, t + dt)

    x⁺ = x + (1 / 6) * (k₁ + 2 * k₂ + 2 * k₃ + k₄)

    return x⁺
end

""" 
Returns the derivative of the state, given the current state, parameters, control input, and time.

Arguments:
- state: the current state of the spacecraft                             | State
- parameters: the parameters of the spacecraft                           | Parameters
- control: the control input to apply to the spacecraft                  | Control
- t: the current time                                                    | Epoch

Returns:
- state: the derivative of the state                                     | State
"""
function dynamics(state::State, parameters::Parameters, control::Control, t::Epoch)::State
    u = cross(control.m, parameters.b)
    return (
        r=state.v,
        v=accel_perturbations(t, state.r, state.v),
        q=qdot(state.q, state.ω),
        ω=parameters.J \ (u - cross(state.ω, parameters.J * state.ω))
    )
end

""" 
Integrate the state forward by dt seconds, using the given control input.

Arguments
- state: the current state of the spacecraft                             | State
- parameters: the parameters of the spacecraft                           | Parameters
- control: the control input to apply to the spacecraft                  | Control
- t: the current time                                                    | Epoch
- dt: the time step to integrate forward by                              | Float64

Returns
- state: the state of the spacecraft after the integration               | State
"""
function integrate_state(state::State, parameters::Parameters, control::Control, t::Epoch, dt::Float64)::State
    state⁺ = rk4(state, t, dt, (state, t) -> dynamics(state, parameters, control, t))

    return (
        r=state⁺.r,
        v=state⁺.v,
        q=state⁺.q / norm(state⁺.q), # normalize the quaternion
        ω=state⁺.ω
    )
end

"""
Generates the acceleration for a spacecraft in LEO. Accounts for a variety of factors, 
including spherical harmonics, atmospheric drag, SRP, and thirdbody from sun and moon

ForwardDiff friendly (written by Kevin)
"""
function accel_perturbations(epc::Epoch, r, v;
    mass::Real=1.0, area_drag::Real=0.01, coef_drag::Real=2.3, area_srp::Real=1.0,
    coef_srp::Real=1.8, n_grav::Integer=10, m_grav::Integer=10, third_body::Bool=true)

    # These functions don't like static, so we gotta adjust
    x = [r; v]

    # Compute ECI to ECEF Transformation -> IAU2010 Theory
    PN = bias_precession_nutation(epc)
    E = earth_rotation(epc)
    W = polar_motion(epc)
    R = W * E * PN

    # Compute sun and moon position
    r_sun = sun_position(epc)
    r_moon = moon_position(epc)

    # Compute acceleration (eltype(x) makes this forward diff friendly)
    a = zeros(eltype(x), 3)

    # spherical harmonic gravity
    a += accel_gravity(x, R, n_grav, m_grav)

    # atmospheric drag
    ρ = density_harris_priester(epc, r)
    a += accel_drag([r; v], ρ, mass, area_drag, coef_drag, Array{Real,2}(PN))

    # SRP
    nu = eclipse_cylindrical(x, r_sun)  # conical doesn't work correctly
    a += nu * accel_srp(x, r_sun, mass, area_srp, coef_srp)

    if third_body
        # third body sun
        a += accel_thirdbody_sun(x, r_sun)

        # third body moon
        a += accel_thirdbody_moon(x, r_moon)
    end

    return (a)
end

"""
Initializes a random, viable orbit given a few different terms, usually 
a position 'r' in Cartesian coordinates. Initial velocity may be specified, but 
if specified it will not necessarily result in a stable orbit. 

The initial starting position, velocity, semi-major axis, orientation, and angular 
velocity may be either specified or determined randomly. 

Arguments:
- r:  (Optional) Height above ground that the satellite will start its orbit at    |  Scalar 
- v:  (Optional) Magnitude of initial velocity                                     |  Scalar 
- a:  (Optional) Semi-major axis                                                   |  Scalar 
- q:  (Optional) Initial attitude, as a unit quaternion                            |  [4,]
- ω:  (Optional) Initial angular velocity                                          |  [3,]

Returns:
- x:  Initial state, as (r, v, q, ω)                                               |  State
"""
function initialize_orbit(; r=nothing, v=nothing, a=nothing, q=nothing, ω=nothing, Rₑ=6378.1363e3, μ=3.9860044188e14)::State

    ### POSITION ###

    # If unspecified, generate a random altitude for the satellite 
    _r = !isnothing(r) ? r : (rand(100:1000) * 1000) + Rₑ # Random height, in km 

    # If unspecified, pick some amount of eccentricity 
    _a = !isnothing(a) ? a * _r : rand(1.0:0.05:1.5) * _r   # Semi-major axis. Results in a circular orbit for a == r

    # If unspecified, calculate the necessary initial velocity to maintain a valid orbit 
    _v = !isnothing(v) ? v : sqrt(μ * ((2 / _r) - (1 / _a)))

    # Now we have to pick directions for r and v... 
    axes = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    ax = rand(1:3)
    r₀ = _r * splice!(axes, ax)  # removes the selected axis from axes 
    v₀ = _v * rand(axes)         # Remaining options are both perpendicular and valid 

    #   allow for negative axes...
    r₀ = (randn() > 0.0) ? r₀ : -r₀
    v₀ = (randn() > 0.0) ? v₀ : -v₀


    ### ORIENTATION ###

    # If unspecified, generate a random starting orientation
    q₀ = !isnothing(q) ? q : randn(4)
    q₀ /= norm(q₀)  # Ensure it is unit 

    # If unspecified, generate a random starting angular velocity
    ω₀ = !isnothing(ω) ? ω : 0.5 * randn(3)

    return (r=r₀, v=v₀, q=q₀, ω=ω₀)
end

"""
Updates the free parameters given the state and time, 
then calls the control function to compute the control input.

Arguments:
- state:   Current state of the system, as a State struct            |  State
- params:  Free parameters of the system, as a Parameters struct     |  Parameters
- control: Control function of state, parameters, and time           |  Function
- t:       Current time, as an Epoch struct                          |  Epoch

Returns:
- control: Control input of the Satellite                            |  Control
"""
function control_step(state::State, params::Parameters, control_fn, t::Epoch)::Control
    params.b = IGRF13(state.r, t)
    return control_fn(state, params, t)
end

"""
steps the simulation forward by one time step, dt.
given the current state, free parameters, control function, and time.

Arguments:
- state:   Current state of the system, as a State struct            |  State
- params:  Free parameters of the system, as a Parameters struct     |  Parameters
- control: Control input of the Satellite                            |  Control
- t:       Current time, as an Epoch struct                          |  Epoch
- dt:      Time step, in seconds                                     |  Scalar

Returns:
- state:   Updated state of the system, as a State struct            |  State
- t:       Updated time, as an Epoch struct                          |  Epoch
"""
function sim_step(state::State, params::Parameters, control::Control, t::Epoch, dt::Float64)::Tuple{State,Epoch}
    state = integrate_state(state, params, control, t, dt)
    t += dt
    return (state, t)
end

function uplink(uplink)
    try
        str = read(uplink, MAGIC_PACKET_SIZE)
        return MsgPack.unpack(str)
    catch e 
        if isa(e, EOFError)
            throw(error("Satellite uplink pipe closed, check /tmp/satlog.txt for details"))
        else
            throw(e)
        end
    end
end

function downlink(fd, state, params)
    sensors = Dict(
        :ω => state.ω,
        :b => params.b,
    )
    truncate(fd, 0)
    seek(fd, 0)
    payload = MsgPack.pack(sensors)
    write(fd, payload)
    flush(fd)
end

function update_parameters(state, params, time)
    params.b = IGRF13(state.r, time)
end

function mk_fifo()
    try
        # remove old fifo, if it exists
        run(`rm -f /tmp/satuplink`)
        # create a new fifo
        run(`mkfifo /tmp/satuplink`)
    catch e
        println("Failed to create uplink fifo: $e")
    end
    println("Created uplink fifo")
end

function initialize_params()
    J = [0.3 0 0; 0 0.3 0; 0 0 0.3]  # Arbitrary inertia matrix for the Satellite 
    params = Parameters(J, [0.0, 0.0, 0.0])
    return params
end

mutable struct FunctionSim
    dt::Float64
    control::Control
end

"""
Runs the simulation, given a control function.
Optionally takes in functions to initialize and update the log.

Arguments:
- control_fn:  Function to compute control input, given state, params, and time      |  Function
- log_init:    (Optional) Function to initialize the log, given the number of steps  |  Function
- log_step:    (Optional) Function to update the log, given the current state        |  Function

Returns:
- hist:        Generated log of the simulation
"""
function simulate(control::Function; log_init=default_log_init, log_step=default_log_step, max_iterations=1000, dt=0.5)
    function setup()
        return FunctionSim(dt, Control([0.0, 0.0, 0.0]))
    end
    function step(sim, state, params, time)
        sim.control = control(state, params, time)
    end
    function cleanup(sim)
        return
    end
    return simulate_helper(setup, step, cleanup, log_init, log_step, max_iterations)

end

mutable struct SocketSim
    dt::Float64
    satellite_process::Base.Process
    uplink_fd::IOStream
    downlink_fd::IOStream
    control::Control
end

function simulate(launch::Cmd; log_init=default_log_init, log_step=default_log_step, max_iterations=1000)
    function setup()
        mk_fifo()
        println("Launching satellite")
        satellite_process = run(launch, wait=false)
        println("Attmepting to establish uplink...")
        # opening uplink file waits for a process to open it for writing
        uplink_fd = open("/tmp/satuplink", "r")
        println("Established uplink!")
        println("Attmepting to establish downlink...")
        downlink_fd = open("/tmp/satdownlink", write=true, create=true)
        println("Established downlink!")
        return SocketSim(0.5, satellite_process, uplink_fd, downlink_fd, Control([0.0, 0.0, 0.0]))
    end
    function step(sim, state, params, time)
        if sim.satellite_process.exitcode >= 0 
            throw(error("Satellite process exited with code $(sim.satellite_process.exitcode), check /tmp/satlog.txt for details"))
        end
        downlink(sim.downlink_fd, state, params)
        uplink_data = uplink(sim.uplink_fd)
        sim.control = Control(uplink_data["m"])
        sim.dt = uplink_data["dt"]
    end
    function cleanup(sim)
        kill(sim.satellite_process)
        println("Killed satellite process")
    end
    return simulate_helper(setup, step, cleanup, log_init, log_step, max_iterations)
end

function simulate_helper(setup::Function, step::Function, cleanup::Function, log_init::Function, log_step::Function, max_iterations)
    state = initialize_orbit()
    println("intialized orbit!")

    params = initialize_params()

    start_time = Epoch(2020, 11, 30)
    time = start_time
    hist = log_init(state)
    time_hist = [0.0]

    sim = setup()
    try  
        for i = 1:max_iterations
            update_parameters(state, params, time)
            step(sim, state, params, time)
            (state, time) = sim_step(state, params, sim.control, time, sim.dt)
            log_step(hist, state)
            append!(time_hist, time - start_time)
            print("\r\033[K")
            @printf("[%d/%d]: norm(ω)=%.3f r=<%.3f %.3f %.3f> b=<%.3f %.3f %.3f> dt=%.3f",
                i, max_iterations, norm(state.ω), state.r[1], state.r[2], state.r[3], params.b[1],
                params.b[2], params.b[3], sim.dt)
            if norm(state.ω) < 0.01
                break
            end
        end
        print("\n")
        cleanup(sim)
        println("Simulation complete!")

        hist = reduce(hcat, hist)
        hist = hist'
        return (hist, time_hist)
    catch e 
        println("Simulation failed: $e")
        cleanup(sim)
        throw(e)
    end

end

"""
Default function to initialize the log, only logs angular velocity and magnitude.

Arguments:
- state:       Current state of the system, as a State struct            |  State
- iterations:  Number of iterations the simulation is run                |  Scalar

Returns:
- hist:        Initialized log of the simulation                         |  Matrix
"""
function default_log_init(state)
    return [[state.ω; norm(state.ω)]]
end

"""
Default function to update the log, only logs angular velocity and magnitude.

Arguments:
- hist:        Log of the simulation                                     |  Matrix
- state:       Current state of the system, as a State struct            |  State
"""
function default_log_step(hist, state)
    point = [state.ω; norm(state.ω)]
    push!(hist, point)
end

end