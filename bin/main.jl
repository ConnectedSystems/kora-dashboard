using DotEnv

DotEnv.load!()

include(joinpath(@__DIR__, "..", "src", "main.jl"))

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
app = create_dashboard()

server = Bonito.Server(app, url, port; proxy_url=proxy)
Bonito.Page(; listen_port=port, proxy_url=proxy)
route!(server, "/" => app)
# route!(server, "/coralflow/" => app)

# Display URL
url_to_visit = online_url(server, "/")
@info "Website launched at: $(url_to_visit)"

@info server

# Wait for the server to exit, because if running in an app, the app will
# exit when the script is done.  This makes sure that the app is only closed
# if (a) the server closes, or (b) the app itself times out and is killed externally.
wait(server)
