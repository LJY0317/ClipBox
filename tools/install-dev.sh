#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
app_install_dir=${CLIPBOX_APP_INSTALL_DIR:-"$HOME/Applications"}
app_destination="$app_install_dir/ClipBox.app"
runtime_bin_dir="$HOME/Library/Application Support/ClipBox/bin"
runtime_cli="$runtime_bin_dir/clipbox"
bundle_id=io.github.LJY0317.ClipBox

assert_replaceable_app() {
    app=$1
    if [ ! -e "$app" ]; then
        return
    fi
    plist="$app/Contents/Info.plist"
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)
    if [ "$existing_id" != "$bundle_id" ]; then
        printf '%s\n' "Refusing to replace app with bundle id '$existing_id': $app" >&2
        exit 1
    fi
}

choose_cli_bin_dir() {
    if [ -n "${CLIPBOX_CLI_BIN_DIR:-}" ]; then
        printf '%s\n' "$CLIPBOX_CLI_BIN_DIR"
        return
    fi

    old_ifs=$IFS
    IFS=:
    for candidate in $PATH; do
        case "$candidate" in
            /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin")
                if [ -d "$candidate" ] && [ -w "$candidate" ]; then
                    IFS=$old_ifs
                    printf '%s\n' "$candidate"
                    return
                fi
                ;;
        esac
    done
    IFS=$old_ifs

    mkdir -p "$HOME/.local/bin"
    printf '%s\n' "$HOME/.local/bin"
}

cli_bin_dir=$(choose_cli_bin_dir)
cli_link="$cli_bin_dir/clipbox"

cd "$project_root"

printf '%s\n' 'Building native ClipBox.app...'
packaged_app=$(/bin/sh "$project_root/tools/package-app.sh")

printf '%s\n' 'Building ClipBox CLI...'
swift build -c release --product clipbox
release_bin_dir=$(swift build -c release --show-bin-path)
source_cli="$release_bin_dir/clipbox"

old_requirement=''
if [ -d "$app_destination" ]; then
    old_requirement=$(/usr/bin/codesign -dr - "$app_destination" 2>&1 | tail -1 || true)
fi
new_requirement=$(/usr/bin/codesign -dr - "$packaged_app" 2>&1 | tail -1 || true)
if printf '%s' "$old_requirement" | /usr/bin/grep -q 'cdhash H' && \
   printf '%s' "$new_requirement" | /usr/bin/grep -q 'cdhash H' && \
   [ "$old_requirement" != "$new_requirement" ]; then
    printf '%s\n' 'Note: this development build uses a new ad-hoc code identity. macOS privacy grants tied to the previous ClipBox CDHash may not carry over.'
    printf '%s\n' 'Set CLIPBOX_CODESIGN_IDENTITY to a stable local code-signing identity when repeated TCC-protected browser access is required.'
elif printf '%s' "$old_requirement" | /usr/bin/grep -q 'cdhash H' && \
     ! printf '%s' "$new_requirement" | /usr/bin/grep -q 'cdhash H'; then
    printf '%s\n' 'ClipBox is moving from ad-hoc signing to a stable certificate-based identity.'
    printf '%s\n' 'A one-time macOS privacy re-approval may be required for this newly identified app.'
elif [ -n "$old_requirement" ] && [ "$old_requirement" != "$new_requirement" ] && \
     ! printf '%s' "$old_requirement" | /usr/bin/grep -q 'cdhash H' && \
     ! printf '%s' "$new_requirement" | /usr/bin/grep -q 'cdhash H'; then
    printf '%s\n' 'Warning: the certificate-based designated requirement changed between installed and new ClipBox builds.' >&2
    printf '%s\n' 'Review the signing identity before relying on existing macOS privacy grants.' >&2
fi

mkdir -p "$app_install_dir" "$runtime_bin_dir" "$cli_bin_dir"
assert_replaceable_app "$app_destination"
rm -rf "$app_destination"
/usr/bin/ditto "$packaged_app" "$app_destination"

cp "$source_cli" "$runtime_cli"
chmod 755 "$runtime_cli"

if [ -e "$cli_link" ] || [ -L "$cli_link" ]; then
    if [ -L "$cli_link" ] && [ "$(readlink "$cli_link")" = "$runtime_cli" ]; then
        rm "$cli_link"
    else
        printf '%s\n' "Refusing to replace existing command at $cli_link" >&2
        exit 1
    fi
fi
ln -s "$runtime_cli" "$cli_link"

/usr/bin/codesign --verify --strict "$app_destination"

printf '%s\n' ''
printf '%s\n' 'ClipBox development install complete.'
printf '  App: %s\n' "$app_destination"
printf '  CLI: %s -> %s\n' "$cli_link" "$runtime_cli"

case ":$PATH:" in
    *":$cli_bin_dir:"*) ;;
    *)
        printf '%s\n' "  Note: $cli_bin_dir is not currently in PATH. Add it to your shell PATH to run 'clipbox' by name."
        ;;
esac
