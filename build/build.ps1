# Run from project root like:
# ./build/build.ps1

Measure-Command {
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue build/kora_app

juliac `
  --output-exe kora_app `
  --bundle build/kora_app `
  --trim=no `
  --jl-option threads=4 `
  --experimental `
  --project . `
  bin/main.jl

# After juliac compiles, copy data and assets into the bundle
Copy-Item -Recurse -Force data  build\kora_app\data
Copy-Item -Recurse -Force assets build\kora_app\assets

# Copy app info
Copy-Item build/README.md build/kora_app/README.md
Copy-Item LICENSE build/kora_app/LICENSE

# Create launch script
@'
& "$PSScriptRoot\bin\kora_app.exe"
'@ | Set-Content -Path build\kora_app\launch.ps1 -Encoding UTF8

Compress-Archive -Path build\kora_app -DestinationPath build\kora_app.zip
}