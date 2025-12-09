using WGLMakie
using Dates
using Bonito, Bonito.Observables
using CSV, DataFrames, NCDatasets, YAXArrays
using CoralFlow
using Statistics

import Bonito.TailwindDashboard as D

# Process EcoRRAP data to create models
@info "Processing EcoRRAP data to create models..."
model_results = CoralFlow.process_ecorrap_models(
    "data/ecorrap_adult_juv_combined_2021_2023_24062025.csv",
    "data/ecorrap to cscape species.csv";
    region="offshore_north",
    save_models=false,
    plot_validation=false,
    growth_degree=1
)

# Extract the fitted models
growth_models = model_results.growth_fits
survival_models = model_results.survival_fits

@info "Models created successfully!"

function update_display(ax1, reef_state, env_conditions, dt, tv, cv, mv)
    # Reset the reef state for new simulation
    CoralFlow.reset!(reef_state)
    initialize_coral_population!(
        reef_state, 1, ceil(Int64, 3 * 60.0); group_proportions=fill(0.2f0, 5)
    )

    # Configure deployments based on slider values
    reef_state.deployment_times .= 0  # reset deployment tracker
    reef_state.deployment_times[dt:end, :, 1] .= tv  # Tabular Acropora
    reef_state.deployment_times[dt:end, :, 2] .= cv  # Corymbose Acropora
    reef_state.deployment_times[dt:end, :, 4] .= mv  # Small massives

    # Run model
    try
        CoralFlow.run_example!(reef_state, env_conditions)
    catch e
        @warn "Model run failed: $e"
        # close(cb)
        return nothing
    end

    # Draw on top of existing runs
    lines!(ax1, coral_cover(reef_state); alpha=0.5)

    return nothing
    # return close(cb)
end

function create_dashboard()
    dhw_datasets = joinpath(@__DIR__, "..", "data", "DHWs")
    dhw45 = NCDataset(joinpath(dhw_datasets, "dhwRCP45.nc"))
    target_site = "Moore_16071_Slope_66"
    target_col = first(findall(dhw45["reef_siteid"][:] .== target_site))

    # Add CSS
    styling = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "db_display.css"))

    # Create the app
    app = App(; title="CoralFlow") do
        # Model parameters
        n_years = 75
        n_locs = 1

        area = 60.0       # in m² (e.g., 30m x 2m transect)
        pop_density = 10  # per m²

        # Create sliders for deployment volumes
        max_deploy_density = Int(5 * area)
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

        # Add deployment time slider
        default_deploy_year = 1
        deploy_time = Bonito.Slider(
            1:n_years;
            value=default_deploy_year,
            label="Deployment Time",
            interrupt=true
        )

        # Initialize model with the fitted models
        reef_state = initialize_reef(;
            n_timesteps=n_years,
            n_locs=n_locs,
            area=area,
            density=pop_density,
            depths=7.0,
            growth_models=growth_models,  # Use the fitted models directly
            survival_models=survival_models
        )

        env_conditions = generate_example_environment(n_years, n_locs; with_dhw=false)

        # Replace example DHWs with one for a slopey site on Moore Reef
        dhw_seq = dhw45["dhw"][:, target_col, 1]
        env_conditions[1:length(dhw_seq), 1, 1] .= dhw_seq

        # Initialize population and run initial simulation
        initialize_coral_population!(
            reef_state, 1, ceil(Int64, 3 * area); group_proportions=fill(0.2f0, 5)
        )
        CoralFlow.run_example!(reef_state, env_conditions)

        # Create figure for visualization
        fig = Figure(; size=(800, 600))
        ax1 = Axis(fig[1, 1];
            title="Coral Cover Over Time\nTransect Area: $(area)m²",
            xlabel="Timestep",
            ylabel="Cover [m²]"
        )
        ax2 = Axis(fig[2, 1];
            title="Heat Stress [DHW]",
            xlabel="Timestep",
            ylabel="Degree Heating Weeks"
        )

        # Initial plots
        initial_cover = coral_cover(reef_state)
        lines!(ax1, initial_cover)
        lines!(ax2, mean(env_conditions[:, :, At(:dhw)].data; dims=2)[:])

        # redraw_limit = nothing
        on(run_button.value) do click
            @info "Running"
            tv = tabular_volume.value
            cv = corymbose_volume.value
            mv = massive_volume.value
            dt = deploy_time.value

            # if @isdefined(redraw_limit) && !isnothing(redraw_limit)
            #     close(redraw_limit)
            # end

            if tv == cv == mv == 0
                # if @isdefined(redraw_limit) && !isnothing(redraw_limit)
                #     close(redraw_limit)
                # end
                return nothing
            end

            @async update_display(
                ax1, reef_state, env_conditions, dt[], tv[], cv[], mv[]
            )

            @info "Finished"
        end

        return DOM.div(
            styling,
            DOM.div(
                DOM.div(
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
                    DOM.div(run_button);
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
