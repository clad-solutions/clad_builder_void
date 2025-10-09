export VSCODE_CLI_APP_NAME="clad"
export VSCODE_CLI_BINARY_NAME="clad-server"
export VSCODE_CLI_DOWNLOAD_URL="https://github.com/clad-solutions/clad_ide_binaries/releases"
export VSCODE_CLI_QUALITY="stable"
# Update URL not needed for Clad
# export VSCODE_CLI_UPDATE_URL="https://raw.githubusercontent.com/clad-solutions/clad-versions/refs/heads/main"

cargo build --release --target aarch64-apple-darwin --bin=code

cp target/aarch64-apple-darwin/release/code "../../VSCode-darwin-arm64/Clad.app/Contents/Resources/app/bin/clad-tunnel"

"../../VSCode-darwin-arm64/Clad.app/Contents/Resources/app/bin/clad-tunnel" serve-web


# export CARGO_NET_GIT_FETCH_WITH_CLI="true"
# export VSCODE_CLI_APP_NAME="clad"
# export VSCODE_CLI_BINARY_NAME="clad-server-insiders"
# export VSCODE_CLI_DOWNLOAD_URL="https://github.com/clad-solutions/clad_ide_void-insiders/releases"
# export VSCODE_CLI_QUALITY="insider"
# export VSCODE_CLI_UPDATE_URL="https://raw.githubusercontent.com/VSCodium/versions/refs/heads/master"

# cargo build --release --target aarch64-apple-darwin --bin=code

# cp target/aarch64-apple-darwin/release/code "../../VSCode-darwin-arm64/VSCodium - Insiders.app/Contents/Resources/app/bin/codium-tunnel-insiders"

# "../../VSCode-darwin-arm64/VSCodium - Insiders.app/Contents/Resources/app/bin/codium-insiders" serve-web
