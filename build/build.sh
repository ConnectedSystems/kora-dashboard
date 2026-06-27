# Run from project root like:
# sh ./build/build.sh

rm -rf build/kora_app

time juliac \
  --output-exe kora_app \
  --bundle build/kora_app \
  --trim=no \
  --jl-option threads=4 \
  --experimental \
  --project . \
  bin/main.jl

cp build/README.md build/kora_app/README.md
cp LICENSE build/kora_app/LICENSE

# After juliac compiles, copy data and assets into the bundle
cp -r data build/kora_app/data
cp -r assets build/kora_app/assets

# Create launch scripts
cat > build/kora_app/launch.sh << 'EOF'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/bin/kora_app"
EOF
chmod +x build/kora_app/launch.sh

cat > build/kora_app/launch.ps1 << 'EOF'
& "$PSScriptRoot\bin\kora_app.exe"
EOF

tar -czf build/kora_app.tar.gz -C build kora_app