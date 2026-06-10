using Base.Threads
using Dates
using Random
using Statistics
using WGLMakie
using Bonito, Bonito.Observables
using CSV, DataFrames, NCDatasets, Parquet2, YAXArrays
using Kora

import Bonito.TailwindDashboard as D
import Kora: process_ecorrap_models

const DATA_DIR = joinpath(@__DIR__, "..", "data")
const ECORRAP_FILE = joinpath(DATA_DIR, "ecorrap_expanded.parquet")
const FG_FILE = joinpath(DATA_DIR, "ecorrap_to_cscape_species.csv")
const OUTPUT_DIR = joinpath(DATA_DIR, "models")
const RUNS_PER_CLICK = 25
const BASE_SEED = 148

# Process EcoRRAP data to create models
@info "Processing EcoRRAP data to create models..."
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

# Extract the fitted models
growth_models = model_results.growth_fits
survival_models = model_results.survival_fits

@info "Models created successfully!"

function color_for_click(click::Int)
    palette = Makie.wong_colors()
    return palette[mod1(click, length(palette))]
end

function simulate_covers(reef_state, env_conditions, dt, tv, cv, mv, n_runs)
    covers = Vector{Union{Nothing,Vector{Float32}}}(undef, n_runs)

    # Run simulations in parallel. Each run gets an independent reef copy.
    @threads for run_id in 1:n_runs
        local_reef_state = copy(reef_state)
        rng = Random.default_rng()
        Random.seed!(rng, BASE_SEED + run_id - 1)

        try
            Kora.reset!(local_reef_state)
            initialize_coral_population!(
                local_reef_state,
                1,
                ceil(Int64, 3 * maximum(local_reef_state.carrying_capacity));
                group_proportions=fill(0.2f0, 5),
                rng=rng
            )

            # Configure deployments based on slider values
            local_reef_state.deployment_times .= 0  # reset deployment tracker
            local_reef_state.deployment_times[dt:end, :, 1] .= tv  # Tabular Acropora
            local_reef_state.deployment_times[dt:end, :, 2] .= cv  # Corymbose Acropora
            local_reef_state.deployment_times[dt:end, :, 4] .= mv  # Small massives

            Kora.run_model!(local_reef_state, env_conditions; rng=rng)
            covers[run_id] = collect(coral_cover(local_reef_state))
        catch e
            @warn "Model run $run_id failed: $e"
            covers[run_id] = nothing
        end
    end

    return covers
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
        massive_volume = Bonito.Slider(
            0:5:max_deploy_density;
            value=0,
            label="Small Massives Deployment",
            interrupt=true
        )
        run_button = Button("Run")
        reset_button = Button("Reset")

        # Add deployment time slider
        default_deploy_year = 1
        deploy_time = Bonito.Slider(
            1:n_years;
            value=default_deploy_year,
            label="Deployment Time",
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
        fig = Figure(; size=(800, 600))
        ax1 = Axis(fig[1, 1];
            title="Coral Cover Over Time\nReef Area: $(area_ref[])m²",
            xlabel="Timestep",
            ylabel="Cover [m²]"
        )
        ax2 = Axis(fig[2, 1];
            title="Heat Stress [DHW]",
            xlabel="Timestep",
            ylabel="Degree Heating Weeks"
        )

        # Initial plots (same 50-run ensemble behavior as Run button)
        initial_covers_ref = Ref(simulate_covers(
            reef_state_ref[],
            env_conditions,
            default_deploy_year,
            0,
            0,
            0,
            RUNS_PER_CLICK
        ))
        traces_ref = Ref(plot_covers!(ax1, initial_covers_ref[], color_for_click(1)))
        lines!(ax2, mean(env_conditions[:, :, At(:dhw)].data; dims=2)[:])

        on(reset_button.value) do _
            @async begin
                fade_out_traces!(ax1, traces_ref[])
                traces_ref[] = plot_covers!(ax1, initial_covers_ref[], color_for_click(1))
            end
        end

        on(area_input.value) do val_str
            area_val = tryparse(Float64, strip(val_str))
            if isnothing(area_val) || area_val <= 0
                return nothing
            end
            area_ref[] = area_val

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
            initial_covers_ref[] = simulate_covers(
                reef_state_ref[],
                env_conditions,
                default_deploy_year,
                0,
                0,
                0,
                RUNS_PER_CLICK
            )

            # Reset plot and update title
            fade_out_traces!(ax1, traces_ref[])
            traces_ref[] = plot_covers!(ax1, initial_covers_ref[], color_for_click(1))
            ax1.title[] = "Coral Cover Over Time\nReef Area: $(area_val)m²"
        end

        run_click_count = Ref(1)
        run_in_progress = Threads.Atomic{Bool}(false)
        run_status_text = Observable("Idle")
        run_status_class = Observable("run-status idle")

        # Reactive info-panel observables
        # Total corals deployed per year (sum across all three groups)
        total_deployed_obs = map(
            (tv, cv, mv) -> tv + cv + mv,
            tabular_volume, corymbose_volume, massive_volume
        )
        # Mean colony density per m² – derived from total and current area
        mean_density_obs = map(
            (tv, cv, mv) -> begin
                a = area_ref[]
                a > 0 ? round((tv + cv + mv) / a; digits=2) : 0.0
            end,
            tabular_volume, corymbose_volume, massive_volume
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
            mv_val = Int(massive_volume.value[])
            dt_val = Int(deploy_time.value[])

            @info "Running" deployment_start_year = dt_val tabular_per_year = tv_val corymbose_per_year = cv_val massive_per_year = mv_val
            run_click_count[] += 1
            run_color = color_for_click(run_click_count[])

            # if @isdefined(redraw_limit) && !isnothing(redraw_limit)
            #     close(redraw_limit)
            # end

            if tv_val == 0 && cv_val == 0 && mv_val == 0
                run_status_text[] = "Idle (no deployments configured)"
                run_status_class[] = "run-status idle"
                # if @isdefined(redraw_limit) && !isnothing(redraw_limit)
                #     close(redraw_limit)
                # end
                return nothing
            end

            current_reef = reef_state_ref[]
            run_in_progress[] = true
            run_status_text[] = "Running $(RUNS_PER_CLICK) simulations..."
            run_status_class[] = "run-status running"
            Threads.@spawn begin
                started_at = time()
                try
                    covers = simulate_covers(
                        current_reef,
                        env_conditions,
                        dt_val,
                        tv_val,
                        cv_val,
                        mv_val,
                        RUNS_PER_CLICK
                    )
                    traces_ref[] = vcat(traces_ref[], plot_covers!(ax1, covers, run_color))
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
                        DOM.label("Reef area (m²):"; class="control-label"),
                        area_input
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
                                dtv -> "Deployed tabular Acropora per year ($(dtv)):",
                                tabular_volume
                            );
                            class="control-label"
                        ),
                        tabular_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                dcv -> "Deployed corymbose Acropora per year ($(dcv)):",
                                corymbose_volume
                            );
                            class="control-label"
                        ),
                        corymbose_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(
                                smv -> "Deployed small massives per year ($(smv)):",
                                massive_volume
                            );
                            class="control-label"
                        ),
                        massive_volume
                    ),
                    DOM.div(
                        DOM.label(
                            map(dst -> "Start deployments (Year $(dst)):", deploy_time);
                            class="control-label"
                        ),
                        deploy_time
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
