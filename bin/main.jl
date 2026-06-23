using DotEnv

include(joinpath(@__DIR__, "..", "src", "main.jl"))

function @main(ARGS)
    local_env_file = joinpath(@__DIR__, "..", ".env.local")
    if isfile(local_env_file)
        DotEnv.load!(local_env_file)
        @info "Loaded local development environment file: .env.local"
    elseif isfile("./.env")
        DotEnv.load!()
    else
        @info "No env file found, reverting to default local config"

        env_d = DotEnv.parse("""
        IP="127.0.0.1"
        PORT="8080"
        PROXY="http://127.0.0.1:8080"
        """)

        merge!(ENV, env_d)
    end

    url = get(ENV, "JULIAHUB_APP_URL", "")
    if isempty(url)
        url = get(ENV, "IP", "0.0.0.0")
    end

    proxy = get(ENV, "PROXY", "")
    if isempty(proxy)
        @info "No Bonito proxy found in environment variable JULIAHUB_APP_URL"
        proxy = ENV["PROXY"]
    else
        @info "Using Bonito proxy from JULIAHUB_APP_URL: $proxy"
    end

    # Use default port if not defined
    port = parse(Int, get(ENV, "PORT", "8080"))

    # Run the dashboard
    app = Base.invokelatest(create_dashboard)

    server = Bonito.Server(app, url, port; proxy_url=proxy)
    route!(server, "/" => app)

    # Display URL
    url_to_visit = online_url(server, "/")
    @info "Website launched at: $(url_to_visit)"

    @info server

    # Open in default browser
    if Sys.iswindows()
        run(`cmd /c start $url_to_visit`)
    elseif Sys.isapple()
        run(`open $url_to_visit`)
    else  # Linux
        run(`xdg-open $url_to_visit`)
    end

    # Wait for the server to exit, because if running in an app, the app will
    # exit when the script is done.  This makes sure that the app is only closed
    # if (a) the server closes, or (b) the app itself times out and is killed externally.
    wait(server)

    return 0
end

# juliac \
#   --output-exe app_test_exe \
#   --bundle build \
#   --trim=safe \
#   --experimental \
#   bin/main.jl

# Powershell
# Measure-Command {
# juliac `
#   --output-exe kora_app `
#   --bundle build/kora_app `
#   --trim=no `
#   --jl-option threads=4 `
#   --experimental `
#   --project . `
#   bin/main.jl
# }
