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
const MIN_REEF_AREA_M2 = 30.0
const MAX_REEF_AREA_M2 = 500.0

include("sim_helpers.jl")
include("plot_helpers.jl")

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

function create_dashboard()
    dhw_datasets = joinpath(@__DIR__, "..", "data", "DHWs")
    dhw45 = NCDataset(joinpath(dhw_datasets, "dhwRCP45.nc"))
    target_site = "Moore_16071_Slope_66"
    target_col = first(findall(dhw45["reef_siteid"][:] .== target_site))
    dhw_seq = dhw45["dhw"][:, target_col, 1]
    n_years = length(dhw_seq)

    # Add CSS
    styling = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "db_display.css"))

    # Create the app
    app = App(; title="Kora") do
        # Model parameters
        n_locs = 1

        pop_density = 10  # per m²
        area_ref = Ref(72.0)  # current reef area in m²
        area_obs = Observable(area_ref[])
        area_validation_text = Observable("")
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
        cover_traces_ref = Ref(plot_covers!(ax1, initial_outputs_ref[].covers, INITIAL_RUN_COLOR))
        group_traces_ref = Ref(
            plot_group_trajectories!(ax2, ensemble_group_summary(initial_outputs_ref[].group_covers))
        )

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

        initial_cover_label_text = map(
            (pct, area, validation_text) -> begin
                if !isempty(validation_text)
                    return validation_text
                end
                return "Initial coral cover [$(pct)% = $(round(pct / 100.0 * area; digits=2)) m²]:"
            end,
            init_cover_pct,
            area_obs,
            area_validation_text
        )
        initial_cover_label_class = map(
            txt -> isempty(txt) ? "control-label" : "control-label validation-error",
            area_validation_text
        )

        on(reset_button.value) do _
            @async begin
                run_status_text[] = "Resetting..."
                run_status_class[] = "run-status running"
                initial_outputs_ref[] = simulate_outputs(
                    reef_state_ref[],
                    env_conditions,
                    default_deploy_year,
                    1,
                    [0, 0, 0, 0, 0],
                    RUNS_PER_CLICK;
                    init_cover_fraction=Float32(init_cover_pct.value[]) / 100f0
                )
                baseline_traces = reset_baseline_plots!(
                    ax1,
                    ax2,
                    initial_outputs_ref[],
                    INITIAL_RUN_COLOR,
                    cover_traces_ref[],
                    group_traces_ref[]
                )
                cover_traces_ref[] = baseline_traces.cover_traces
                group_traces_ref[] = baseline_traces.group_traces
                run_status_text[] = "Reset complete"
                run_status_class[] = "run-status completed"
            end
        end

        on(area_input.value) do val_str
            area_val = tryparse(Float64, strip(val_str))
            if isnothing(area_val)
                area_validation_text[] = "Reef area must be numeric ($(Int(MIN_REEF_AREA_M2))-$(Int(MAX_REEF_AREA_M2)) m²)."
                return nothing
            end
            if area_val < MIN_REEF_AREA_M2 || area_val > MAX_REEF_AREA_M2
                area_validation_text[] = "Initial coral cover [reef area must be between $(Int(MIN_REEF_AREA_M2)) and $(Int(MAX_REEF_AREA_M2)) m²]:"
                return nothing
            end

            area_validation_text[] = ""
            area_ref[] = area_val
            area_obs[] = area_val
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
            baseline_traces = reset_baseline_plots!(
                ax1,
                ax2,
                initial_outputs_ref[],
                INITIAL_RUN_COLOR,
                cover_traces_ref[],
                group_traces_ref[]
            )
            cover_traces_ref[] = baseline_traces.cover_traces
            group_traces_ref[] = baseline_traces.group_traces
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
                        baseline_traces = reset_baseline_plots!(
                            ax1,
                            ax2,
                            initial_outputs_ref[],
                            INITIAL_RUN_COLOR,
                            cover_traces_ref[],
                            group_traces_ref[]
                        )
                        cover_traces_ref[] = baseline_traces.cover_traces
                        group_traces_ref[] = baseline_traces.group_traces
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
                        cover_traces_ref[] = vcat(
                            cover_traces_ref[],
                            plot_covers!(ax1, outputs.covers, run_color)
                        )
                        group_traces_ref[] = plot_group_trajectories!(
                            ax2,
                            ensemble_group_summary(outputs.group_covers)
                        )
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
                            initial_cover_label_text;
                            class=initial_cover_label_class
                        ),
                        init_cover_pct
                    ),
                    DOM.h3("Simulation Info"),
                    DOM.div(
                        DOM.div(
                            DOM.span("Area represented: "; class="info-label"),
                            DOM.span(map(v -> "$(v) m²", area_obs); class="info-value")
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
                                dnav -> "Deployed branching non-Acropora per year [$(dnav)]:",
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
