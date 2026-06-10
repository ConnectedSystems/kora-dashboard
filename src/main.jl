using Base.Threads
using Random
using Statistics
using Distributions
using WGLMakie
using Bonito, Bonito.Observables
using NCDatasets, YAXArrays
using Parquet2
using Kora

import Bonito.TailwindDashboard as D
import Kora: load_models, process_ecorrap_models

const DATA_DIR = joinpath(@__DIR__, "..", "data")
const ECORRAP_FILE = joinpath(DATA_DIR, "ecorrap_expanded.parquet")
const FG_FILE = joinpath(DATA_DIR, "ecorrap_to_cscape_species.csv")
const OUTPUT_DIR = joinpath(DATA_DIR, "models")
const GROWTH_MODEL_FILE = joinpath(OUTPUT_DIR, "offshore_north_growth_models.json")
const SURVIVAL_MODEL_FILE = joinpath(OUTPUT_DIR, "offshore_north_survival_models.json")
const RUNS_PER_CLICK = 25
const BASE_SEED = 148
const INITIAL_RUN_COLOR = :gray55

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

const MEAN_COLONY_COVER_M2 = _mean_colony_cover_m2()

const GROUP_LABELS = if isdefined(Kora, :GROUP_NAMES)
    collect(getproperty(Kora, :GROUP_NAMES))
else
    [
        "Tabular Acropora",
        "Corymbose Acropora",
        "branching non-Acropora",
        "Small massives + encrusting",
        "Large massives"
    ]
end

if isfile(GROWTH_MODEL_FILE) && isfile(SURVIVAL_MODEL_FILE)
    @info "Loading saved Kora model specifications..."
    const growth_models = load_models(GROWTH_MODEL_FILE)
    const survival_models = load_models(SURVIVAL_MODEL_FILE)
else
    @info "Saved Kora model specifications not found; processing EcoRRAP data..."
    model_results = process_ecorrap_models(
        ECORRAP_FILE,
        FG_FILE;
        region="offshore_north",
        growth_degree=1,
        survival_degree=2,
        save_models=true,
        output_dir=OUTPUT_DIR,
        plot_validation=false
    )

    const growth_models = model_results.growth_fits
    const survival_models = model_results.survival_fits

    @info "Models created and saved successfully!"
end

function color_for_click(click::Int)
    palette = Makie.wong_colors()
    return palette[mod1(click, length(palette))]
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
            # Convert target cover fraction → colony count using expected m² per colony
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

function plot_covers!(ax1, covers, run_color; alpha=0.35)
    traces = Vector{NamedTuple{(:plot, :alpha),Tuple{Any,Observable{Float64}}}}()

    for cover in covers
        if isnothing(cover)
            continue
        end
        alpha_obs = Observable(alpha)
        plot_obj = lines!(ax1, cover; alpha=alpha_obs, color=run_color)
        push!(traces, (plot=plot_obj, alpha=alpha_obs))
    end

    # Ensure axis limits update to include newly drawn traces.
    autolimits!(ax1)

    return traces
end

function fade_out_traces!(ax1, traces; duration_s=0.35, steps=12)
    if isempty(traces)
        return nothing
    end

    for step in 1:steps
        f = 1.0 - (step / steps)
        for tr in traces
            tr.alpha[] = 0.35 * f
        end
        sleep(duration_s / steps)
    end

    empty!(ax1)
    autolimits!(ax1)
    return nothing
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

function plot_group_trajectories!(ax, group_summary)
    empty!(ax)
    if isnothing(group_summary)
        autolimits!(ax)
        return nothing
    end

    colors = Makie.wong_colors()
    for grp in 1:size(group_summary.median, 2)
        band!(
            ax,
            axes(group_summary.median, 1),
            group_summary.lower[:, grp],
            group_summary.upper[:, grp];
            color=(colors[mod1(grp, length(colors))], 0.2)
        )
        lines!(
            ax,
            group_summary.median[:, grp];
            color=colors[mod1(grp, length(colors))],
            linewidth=2,
            label=GROUP_LABELS[grp]
        )
    end
    autolimits!(ax)

    return nothing
end

function create_dashboard()
    dhw_datasets = joinpath(@__DIR__, "..", "data", "DHWs")
    dhw45 = NCDataset(joinpath(dhw_datasets, "dhwRCP45.nc"))
    target_site = "Moore_16071_Slope_66"
    target_col = first(findall(dhw45["reef_siteid"][:] .== target_site))

    # Add CSS
    styling = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "db_display.css"))

    # Create the app
    app = App(; title="Kora") do
        # Model parameters
        n_years = 75
        n_locs = 1

        pop_density = 10  # per m²
        area_ref = Ref(72.0)  # current reef area in m²
        area_input = Bonito.TextField("$(area_ref[])"; placeholder="Reef area (m²)")

        # Create sliders for deployment volumes
        max_deploy_density = Int(5 * area_ref[])
        tabular_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="Tabular Acropora Deployment",
            interrupt=true
        )
        corymbose_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="Corymbose Acropora Deployment",
            interrupt=true
        )
        non_acro_corymbose_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="branching non-Acropora Deployment",
            interrupt=true
        )
        massive_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="Small Massives Deployment",
            interrupt=true
        )
        large_massive_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="Large Massives Deployment",
            interrupt=true
        )

        # Initial population density as % of maximum possible (density * area)
        init_cover_pct = Bonito.Slider(
            5:5:100;
            value=30,
            label="Initial Population (%)",
            interrupt=true
        )

        run_button = Button("Run")
        reset_button = Button("Reset")

        # Add deployment time slider
        default_deploy_year = 1
        deploy_time = Bonito.Slider(
            1:n_years;
            value=default_deploy_year,
            label="Deployment Start Year",
            interrupt=true
        )
        revisit_cadence = Bonito.Slider(
            1:25;
            value=1,
            label="Deployment Cadence (years)",
            interrupt=true
        )

        # Initialize model with the fitted models
        reef_state_ref = Ref(initialize_reef(;
            n_timesteps=n_years,
            n_locs=n_locs,
            area=area_ref[],
            density=pop_density,
            depths=7.0,
            growth_models=growth_models,  # Use the fitted models directly
            survival_models=survival_models
        ))

        env_conditions = generate_example_environment(n_years, n_locs; with_dhw=false)

        # Replace example DHWs with one for a slopey site on Moore Reef
        dhw_seq = dhw45["dhw"][:, target_col, 1]
        env_conditions[1:length(dhw_seq), 1, 1] .= dhw_seq

        # Create figure for visualization
        fig = Figure(; size=(900, 900))
        ax1 = Axis(fig[1, 1];
            title="Coral Cover Over Time\nReef Area: $(area_ref[])m²",
            xlabel="Timestep",
            ylabel="Cover [m²]"
        )
        ax2 = Axis(fig[2, 1];
            title="Cover by Functional Group",
            xlabel="Timestep",
            ylabel="Cover [m²]"
        )
        ax3 = Axis(fig[4, 1];
            title="Heat Stress [DHW]",
            xlabel="Timestep",
            ylabel="Degree Heating Weeks"
        )

        # Initial plots (same 50-run ensemble behavior as Run button)
        initial_outputs_ref = Ref(simulate_outputs(
            reef_state_ref[],
            env_conditions,
            default_deploy_year,
            1,
            [0, 0, 0, 0, 0],
            RUNS_PER_CLICK;
            init_cover_fraction=Float32(init_cover_pct.value[]) / 100f0
        ))
        traces_ref = Ref(plot_covers!(ax1, initial_outputs_ref[].covers, INITIAL_RUN_COLOR))
        plot_group_trajectories!(ax2, ensemble_group_summary(initial_outputs_ref[].group_covers))

        Legend(
            fig[3, 1],
            ax2;
            orientation=:horizontal,
            tellwidth=false,
            tellheight=true,
            halign=:center,
            valign=:center
        )

        lines!(ax3, mean(env_conditions[:, :, At(:dhw)].data; dims=2)[:])

        last_init_cover_pct = Ref(Int(init_cover_pct.value[]))
        run_click_count = Ref(1)
        run_in_progress = Threads.Atomic{Bool}(false)
        run_status_text = Observable("Idle")
        run_status_class = Observable("run-status idle")

        on(reset_button.value) do _
            @async begin
                run_status_text[] = "Resetting view..."
                run_status_class[] = "run-status running"
                fade_out_traces!(ax1, traces_ref[])
                traces_ref[] = plot_covers!(ax1, initial_outputs_ref[].covers, INITIAL_RUN_COLOR)
                plot_group_trajectories!(
                    ax2,
                    ensemble_group_summary(initial_outputs_ref[].group_covers)
                )
                run_status_text[] = "Reset complete"
                run_status_class[] = "run-status completed"
            end
        end

        on(area_input.value) do val_str
            area_val = tryparse(Float64, strip(val_str))
            if isnothing(area_val) || area_val <= 0
                return nothing
            end
            area_ref[] = area_val
            run_status_text[] = "Resetting for new area..."
            run_status_class[] = "run-status running"

            # Rebuild reef with new area and regenerate initial ensemble
            reef_state_ref[] = initialize_reef(;
                n_timesteps=n_years,
                n_locs=n_locs,
                area=area_val,
                density=pop_density,
                depths=7.0,
                growth_models=growth_models,
                survival_models=survival_models
            )
            initial_outputs_ref[] = simulate_outputs(
                reef_state_ref[],
                env_conditions,
                default_deploy_year,
                Int(revisit_cadence.value[]),
                [
                    Int(tabular_volume.value[]),
                    Int(corymbose_volume.value[]),
                    Int(non_acro_corymbose_volume.value[]),
                    Int(massive_volume.value[]),
                    Int(large_massive_volume.value[])
                ],
                RUNS_PER_CLICK;
                init_cover_fraction=Float32(init_cover_pct.value[]) / 100f0
            )

            # Reset plot and update title
            fade_out_traces!(ax1, traces_ref[])
            traces_ref[] = plot_covers!(ax1, initial_outputs_ref[].covers, INITIAL_RUN_COLOR)
            plot_group_trajectories!(ax2, ensemble_group_summary(initial_outputs_ref[].group_covers))
            ax1.title[] = "Coral Cover Over Time\nReef Area: $(area_val)m²"
            run_status_text[] = "Reset complete"
            run_status_class[] = "run-status completed"
        end

        # Reactive info-panel observables
        # Total corals deployed per year (sum across all three groups)
        total_deployed_obs = map(
            (tv, cv, nav, mv, lmv) -> tv + cv + nav + mv + lmv,
            tabular_volume,
            corymbose_volume,
            non_acro_corymbose_volume,
            massive_volume,
            large_massive_volume
        )
        # Mean colony density per m² – derived from total and current area
        mean_density_obs = map(
            (tv, cv, nav, mv, lmv) -> begin
                a = area_ref[]
                a > 0 ? round((tv + cv + nav + mv + lmv) / a; digits=2) : 0.0
            end,
            tabular_volume,
            corymbose_volume,
            non_acro_corymbose_volume,
            massive_volume,
            large_massive_volume
        )

        # redraw_limit = nothing
        on(run_button.value) do click
            if run_in_progress[]
                @info "Run already in progress; ignoring new click"
                run_status_text[] = "Run already in progress"
                run_status_class[] = "run-status running"
                return nothing
            end

            tv_val = Int(tabular_volume.value[])
            cv_val = Int(corymbose_volume.value[])
            nav_val = Int(non_acro_corymbose_volume.value[])
            mv_val = Int(massive_volume.value[])
            lmv_val = Int(large_massive_volume.value[])
            dt_val = Int(deploy_time.value[])
            revisit_val = Int(revisit_cadence.value[])
            deploy_vals = [tv_val, cv_val, nav_val, mv_val, lmv_val]

            @info "Running" deployment_start_year = dt_val revisit_years = revisit_val deploy_per_year = deploy_vals
            run_click_count[] += 1
            run_color = color_for_click(run_click_count[])

            # if @isdefined(redraw_limit) && !isnothing(redraw_limit)
            #     close(redraw_limit)
            # end

            current_reef = reef_state_ref[]
            pct_val = Int(init_cover_pct.value[])
            init_cover_frac = Float32(pct_val) / 100f0
            cover_pct_changed = pct_val != last_init_cover_pct[]
            last_init_cover_pct[] = pct_val
            no_deployments = all(==(0), deploy_vals)

            if no_deployments && !cover_pct_changed
                run_status_text[] = "Idle (no deployments configured)"
                run_status_class[] = "run-status idle"
                return nothing
            end

            run_in_progress[] = true
            run_status_text[] = "Running ensemble of $(RUNS_PER_CLICK) simulations..."
            run_status_class[] = "run-status running"
            Threads.@spawn begin
                started_at = time()
                try
                    if cover_pct_changed
                        initial_outputs_ref[] = simulate_outputs(
                            current_reef,
                            env_conditions,
                            default_deploy_year,
                            1,
                            [0, 0, 0, 0, 0],
                            RUNS_PER_CLICK;
                            init_cover_fraction=init_cover_frac
                        )
                        fade_out_traces!(ax1, traces_ref[])
                        traces_ref[] = plot_covers!(ax1, initial_outputs_ref[].covers, INITIAL_RUN_COLOR)
                        plot_group_trajectories!(ax2, ensemble_group_summary(initial_outputs_ref[].group_covers))
                    end
                    if !no_deployments
                        outputs = simulate_outputs(
                            current_reef,
                            env_conditions,
                            dt_val,
                            revisit_val,
                            deploy_vals,
                            RUNS_PER_CLICK;
                            init_cover_fraction=init_cover_frac
                        )
                        traces_ref[] = vcat(
                            traces_ref[],
                            plot_covers!(ax1, outputs.covers, run_color)
                        )
                        plot_group_trajectories!(ax2, ensemble_group_summary(outputs.group_covers))
                    end
                finally
                    elapsed_s = round(time() - started_at; digits=2)
                    run_in_progress[] = false
                    @async begin
                        run_status_text[] = "Completed in $(elapsed_s)s"
                        run_status_class[] = "run-status completed"
                    end
                end
            end

            @info "Finished"
        end

        return DOM.div(
            styling,
            DOM.div(
                DOM.div(
                    DOM.h3("Reef Settings"),
                    DOM.div(
                        DOM.label("Reef area [m²]:"; class="control-label"),
                        area_input
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                pct -> "Initial coral cover [$(pct)% = $(round(pct / 100.0 * area_ref[]; digits=2)) m²]:",
                                init_cover_pct
                            );
                            class="control-label"
                        ),
                        init_cover_pct
                    ),
                    DOM.h3("Simulation Info"),
                    DOM.div(
                        DOM.div(
                            DOM.span("Area represented: "; class="info-label"),
                            DOM.span(map(v -> "$(v) m²", area_input); class="info-value")
                        ),
                        DOM.div(
                            DOM.span("Total corals deployed/year: "; class="info-label"),
                            DOM.span(map(v -> "$(v)", total_deployed_obs); class="info-value")
                        ),
                        DOM.div(
                            DOM.span("Mean density: "; class="info-label"),
                            DOM.span(map(v -> "$(v) per m²", mean_density_obs); class="info-value")
                        );
                        class="info-panel"
                    ),
                    DOM.h3("Run Status"),
                    DOM.div(
                        DOM.span(run_status_text; class=run_status_class),
                        class="run-status-panel"
                    ),
                    DOM.h3("Deployment Controls"),
                    DOM.div(
                        DOM.label(
                            map(
                                dtv -> "Deployed tabular Acropora per year [$(dtv)]:",
                                tabular_volume
                            );
                            class="control-label"
                        ),
                        tabular_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                dcv -> "Deployed corymbose Acropora per year [$(dcv)]:",
                                corymbose_volume
                            );
                            class="control-label"
                        ),
                        corymbose_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                dnav -> "Deployed Pocillopora + non-Acropora corymbose per year [$(dnav)]:",
                                non_acro_corymbose_volume
                            );
                            class="control-label"
                        ),
                        non_acro_corymbose_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                smv -> "Deployed small massives per year [$(smv)]:",
                                massive_volume
                            );
                            class="control-label"
                        ),
                        massive_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                lmv -> "Deployed large massives per year [$(lmv)]:",
                                large_massive_volume
                            );
                            class="control-label"
                        ),
                        large_massive_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(dst -> "Start deployments [Year $(dst)]:", deploy_time);
                            class="control-label"
                        ),
                        deploy_time
                    ),
                    DOM.div(
                        DOM.label(
                            map(rc -> "Revisit cadence [every $(rc) year(s)]:", revisit_cadence);
                            class="control-label"
                        ),
                        revisit_cadence
                    ),
                    DOM.div(run_button, reset_button);
                    class="controls-panel"
                ),
                DOM.div(
                    DOM.div(fig; class="plots-container");
                    class="plots-panel"
                );
                class="dashboard-container"
            )
        )
    end

    return app
end
