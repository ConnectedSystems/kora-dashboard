"""
Compute expected cover (m²) per colony averaged across all 5 groups with equal
proportions, sampling from the same truncated log-normal size distributions used
by initialize_coral_population!. Used to convert a target cover fraction to a
target colony count.
"""
function _mean_colony_cover_m2(n_per_grp::Int=20_000)::Float32
    rng = Random.MersenneTwister(0)
    dists = Kora.size_distribution()
    edges = Kora.bin_edges()
    n_grps = size(edges, 1)
    total = 0.0f0
    for grp in 1:n_grps
        d = truncated(dists[grp], 0.0f0, maximum(edges[grp, :]))
        samples = Float32.(rand(rng, d, n_per_grp))
        total += sum(cover_cm_to_m2.(samples))
    end
    return total / (n_per_grp * n_grps)
end

function simulate_outputs(reef_state, env_conditions, dt, revisit_cadence, deploy_volumes, n_runs; init_cover_fraction=0.3f0)
    covers = Vector{Union{Nothing,Vector{Float32}}}(undef, n_runs)
    group_covers = Vector{Union{Nothing,Matrix{Float32}}}(undef, n_runs)

    # Run simulations in parallel. Each run gets an independent reef copy.
    @threads for run_id in 1:n_runs
        local_reef_state = copy(reef_state)
        rng = Random.default_rng()
        Random.seed!(rng, BASE_SEED + run_id - 1)

        try
            Kora.reset!(local_reef_state)
            # Convert target cover fraction -> colony count using expected m² per colony
            target_cover_m2 = init_cover_fraction * maximum(local_reef_state.carrying_capacity)
            target_pop = max(5, ceil(Int64, target_cover_m2 / MEAN_COLONY_COVER_M2))
            initialize_coral_population!(
                local_reef_state,
                1,
                target_pop;
                group_proportions=fill(0.2f0, 5),
                rng=rng
            )

            # Configure deployments based on slider values
            local_reef_state.deployment_times .= 0  # reset deployment tracker
            cadence = max(1, revisit_cadence)
            n_grps = min(length(deploy_volumes), size(local_reef_state.deployment_times, 3))
            for grp in 1:n_grps
                vol = deploy_volumes[grp]
                if vol > 0
                    local_reef_state.deployment_times[dt:cadence:end, :, grp] .= vol
                end
            end

            Kora.run_model!(local_reef_state, env_conditions; rng=rng)
            covers[run_id] = collect(coral_cover(local_reef_state))
            group_covers[run_id] = Matrix(group_cover(local_reef_state))
        catch e
            @warn "Model run $run_id failed: $e"
            covers[run_id] = nothing
            group_covers[run_id] = nothing
        end
    end

    return (covers=covers, group_covers=group_covers)
end

function ensemble_group_summary(group_covers)
    valid = [gc for gc in group_covers if !isnothing(gc)]
    if isempty(valid)
        return nothing
    end

    n_ts, n_groups = size(valid[1])
    lower = zeros(Float32, n_ts, n_groups)
    median_vals = zeros(Float32, n_ts, n_groups)
    upper = zeros(Float32, n_ts, n_groups)
    tmp = zeros(Float32, length(valid))

    for ts in 1:n_ts, grp in 1:n_groups
        for (i, gc) in enumerate(valid)
            tmp[i] = gc[ts, grp]
        end
        lower[ts, grp] = quantile(tmp, 0.025)
        median_vals[ts, grp] = quantile(tmp, 0.5)
        upper[ts, grp] = quantile(tmp, 0.975)
    end

    return (lower=lower, median=median_vals, upper=upper)
end
