#
# A "master" loss function type
#

"""
    struct LossFunction{A, T, F, W, S, M}

A loss function for the analysis of single column models.
"""
struct LossFunction{R, F, W, T, P}
        targets :: R
         fields :: F
        weights :: W
    time_series :: T
        profile :: P
end

function LossFunction(model, data; fields,
                          targets = 1:length(data.t), 
                          weights = nothing,
                      time_series = TimeSeriesAnalysis(data.t[targets], TimeAverage()),
                          profile = ValueProfileAnalysis(model.grid)
                      )

    return LossFunction(targets, fields, weights, time_series, profile)
end

function (loss::LossFunction)(parameters, model_plus_Δt, data)
    evaluate!(loss, parameters, model_plus_Δt, data)
    return loss.time_series.analysis(loss.time_series.data, loss.time_series.time)
end

#
# Time analysis
#

struct TimeSeriesAnalysis{T, D, A}
        time :: T
        data :: D
    analysis :: A
end

TimeSeriesAnalysis(time, analysis) = TimeSeriesAnalysis(time, zeros(length(time)), analysis)

struct TimeAverage end

@inline (::TimeAverage)(data, time) = trapz(data, time) / (time[end] - time[1])

#
# Profile analysis
#

"""
    struct ValueProfileAnalysis{D, A}

A type for doing analyses on a discrepency profile located
at cell centers. Defaults to taking the mean square difference between
the model and data coarse-grained to the model grid.
"""
struct ValueProfileAnalysis{D, A}
    discrepency :: D
       analysis :: A
end

ValueProfileAnalysis(grid; analysis=mean) = ValueProfileAnalysis(CellField(grid), analysis)
ValueProfileAnalysis(; analysis=mean) = ValueProfileAnalysis(nothing, analysis)
on_grid(profile::ValueProfileAnalysis, grid) = ValueProfileAnalysis(grid; analysis=profile.analysis)

function calculate_value_discrepency!(value, model_field, data_field)
    coarse_grained = discrepency = value.discrepency
    set!(coarse_grained, data_field)

    for i in eachindex(discrepency)
        @inbounds discrepency[i] = (coarse_grained[i] - model_field[i])^2
    end
    return nothing
end

"""
    analyze_profile_discrepency(value, model_field, data_field)

Calculates the discrepency between model and data field values, and returns an
analysis of the discrepency profile.
"""
function analyze_profile_discrepency(value, model_field, data_field)
    calculate_value_discrepency!(value, model_field, data_field)
    return value.analysis(value.discrepency)
end

"""
    struct GradientProfileAnalysis{D, A}

A type for combining discprency between the fields and field gradients.
Defaults to taking the mean square difference between
the model and data coarse-grained to the model grid.
"""
mutable struct GradientProfileAnalysis{D, G, F, W, A}
     ϵ :: D
    ∇ϵ :: G
    ∇ϕ :: F
    gradient_weight :: W
    value_weight :: W
    analysis :: A
end

GradientProfileAnalysis(grid; analysis=mean, gradient_weight=1.0, value_weight=1.0) =
    GradientProfileAnalysis(CellField(grid), FaceField(grid), FaceField(grid),
                            gradient_weight, value_weight, analysis)

GradientProfileAnalysis(; analysis=mean, gradient_weight=1.0, value_weight=1.0) = 
    GradientProfileAnalysis(nothing, nothing, nothing, gradient_weight, value_weight, analysis)

function on_grid(profile::GradientProfileAnalysis, grid)
    return GradientProfileAnalysis(grid;        
                                          analysis = profile.analysis, 
                                   gradient_weight = profile.gradient_weight,
                                      value_weight = profile.value_weight)
end
                            
function calculate_gradient_discrepency!(prof, model_field, data_field)
    # Coarse grain the data
    ϵ = prof.ϵ
    set!(ϵ, data_field)

    # Calculate profients of both data and discrepency
    ∇ϕ = prof.∇ϕ
    ∇ϵ = prof.∇ϵ
    ∂z!(∇ϵ, ϵ)
    ∂z!(∇ϕ, model_field)

    for i in eachindex(ϵ)
        @inbounds ϵ[i] = (ϵ[i] - model_field[i])^2
        @inbounds ∇ϵ[i] = (∇ϵ[i] - ∇ϕ[i])^2 # incluϵes bottom boundary value, which will later be ignored.
    end

    # Top boundary contribution (ignored for now)
    #N = d.grid.N
    #@inbounds ∇d[N+1] = (∇d[N+1] - ∇ϕ[N+1])^2 

    return nothing
end

"""
    analyze_profile_discrepency(prof::GradientProfileAnalysis, model_field, data_field)

Calculates the discrepencies between both values and gradients of model and data fields,
and returns an analysis of the two discrepency profiles.
"""
function analyze_profile_discrepency(prof::GradientProfileAnalysis, model_field, data_field)
    calculate_gradient_discrepency!(prof, model_field, data_field)

    # Calculate analysis on gradient, excluding boundary points.
    return prof.analysis(prof.ϵ) + prof.gradient_weight * prof.analysis(prof.∇ϵ.data[2:end-1])
end

#
# Loss function utils
#

@inline get_weight(::Nothing, field_index) = 1
@inline get_weight(weights, field_index) = @inbounds weights[field_index]

function analyze_weighted_profile_discrepency(loss, model, data, target)
    total_discrepency = zero(eltype(model.grid))
    field_names = Tuple(loss.fields)

    for (field_index, field_name) in enumerate(field_names)
        model_field = getproperty(model.solution, field_name)
        data_field = getproperty(data, field_name)[target]

        # Calculate the per-field profile-based disrepency
        field_discrepency = analyze_profile_discrepency(loss.profile, model_field, data_field)

        # Accumulate weighted profile-based disrepencies in the total discrepencyor
        total_discrepency += get_weight(loss.weights, field_index) * field_discrepency # accumulate discrepencyor
    end

    return nan2inf(total_discrepency)
end

function evaluate!(loss, parameters, model_plus_Δt, data)

    # Initialize
    initialize_forward_run!(model_plus_Δt, data, parameters, loss.targets[1])
    @inbounds loss.time_series.data[1] = analyze_weighted_profile_discrepency(loss, model_plus_Δt, data, 1)

    # Calculate a loss function time-series
    for (i, target) in enumerate(loss.targets)
        run_until!(model_plus_Δt.model, model_plus_Δt.Δt, data.t[target])

        @inbounds loss.time_series.data[i] = 
            analyze_weighted_profile_discrepency(loss, model_plus_Δt, data, target) 
    end

    return nothing
end

#
# Miscellanea
#

function max_variance(data, loss::LossFunction)
    max_variances = zeros(length(loss.fields))
    for (ifield, field) in enumerate(loss.fields)
        max_variances[ifield] = get_weight(weight, ifield) * max_variance(data, field, loss.targets)
    end
    return max_variances
end
