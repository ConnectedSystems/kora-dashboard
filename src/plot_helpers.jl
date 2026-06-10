function color_for_click(click::Int)
    palette = Makie.wong_colors()
    return palette[mod1(click, length(palette))]
end

function plot_covers!(ax1, covers, run_color; alpha=0.35)
    traces = Vector{NamedTuple{(:plot, :alpha, :base_alpha),Tuple{Any,Observable{Float64},Float64}}}()

    for cover in covers
        if isnothing(cover)
            continue
        end
        alpha_obs = Observable(alpha)
        plot_obj = lines!(ax1, cover; alpha=alpha_obs, color=run_color)
        push!(traces, (plot=plot_obj, alpha=alpha_obs, base_alpha=Float64(alpha)))
    end

    # Ensure axis limits update to include newly drawn traces.
    autolimits!(ax1)

    return traces
end

function fade_out_traces!(trace_sets...; duration_s=0.2, steps=8)
    traces = reduce(vcat, [collect(trace_set) for trace_set in trace_sets]; init=eltype(first(trace_sets))[])
    if isempty(traces)
        return nothing
    end

    for step in 1:steps
        f = 1.0 - (step / steps)
        for tr in traces
            tr.alpha[] = tr.base_alpha * f
        end
        sleep(duration_s / steps)
    end
    return nothing
end

function plot_group_trajectories!(ax, group_summary)
    empty!(ax)
    if isnothing(group_summary)
        autolimits!(ax)
        return NamedTuple{(:plot, :alpha, :base_alpha),Tuple{Any,Observable{Float64},Float64}}[]
    end

    colors = Makie.wong_colors()
    traces = Vector{NamedTuple{(:plot, :alpha, :base_alpha),Tuple{Any,Observable{Float64},Float64}}}()
    for grp in 1:size(group_summary.median, 2)
        band_alpha = Observable(0.2)
        band_plot = band!(
            ax,
            axes(group_summary.median, 1),
            group_summary.lower[:, grp],
            group_summary.upper[:, grp];
            color=colors[mod1(grp, length(colors))],
            alpha=band_alpha
        )
        push!(traces, (plot=band_plot, alpha=band_alpha, base_alpha=0.2))

        line_alpha = Observable(1.0)
        line_plot = lines!(
            ax,
            group_summary.median[:, grp];
            color=colors[mod1(grp, length(colors))],
            alpha=line_alpha,
            linewidth=2,
            label=GROUP_LABELS[grp]
        )
        push!(traces, (plot=line_plot, alpha=line_alpha, base_alpha=1.0))
    end
    autolimits!(ax)

    return traces
end

function reset_baseline_plots!(ax1, ax2, outputs, run_color, cover_traces, group_traces)
    fade_out_traces!(cover_traces, group_traces)
    empty!(ax1)
    autolimits!(ax1)
    empty!(ax2)
    autolimits!(ax2)

    new_cover_traces = plot_covers!(ax1, outputs.covers, run_color)
    new_group_traces = plot_group_trajectories!(ax2, ensemble_group_summary(outputs.group_covers))

    return (cover_traces=new_cover_traces, group_traces=new_group_traces)
end
