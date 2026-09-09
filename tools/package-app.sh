#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
destination=${1:-"$project_root/dist/ClipBox.app"}
bundle_id=io.github.LJY0317.ClipBox
default_local_identity='ClipBox Local Development Code Signing'

has_codesign_identity() {
    name=$1
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/grep -F "\"$name\"" >/dev/null 2>&1
}

if [ "${CLIPBOX_CODESIGN_IDENTITY+x}" = x ]; then
    codesign_identity=$CLIPBOX_CODESIGN_IDENTITY
    if [ -z "$codesign_identity" ]; then
        printf '%s\n' 'CLIPBOX_CODESIGN_IDENTITY was set but empty.' >&2
        exit 1
    fi
    if [ "$codesign_identity" != '-' ] && ! has_codesign_identity "$codesign_identity"; then
        printf '%s\n' "Requested code-signing identity is unavailable: $codesign_identity" >&2
        exit 1
    fi
elif has_codesign_identity "$default_local_identity"; then
    codesign_identity=$default_local_identity
elif /usr/bin/security find-certificate -a -c "$default_local_identity" 2>/dev/null \
    | /usr/bin/grep -q .; then
    printf '%s\n' "ClipBox local signing certificate exists but is not a usable code-signing identity: $default_local_identity" >&2
    printf '%s\n' 'Refusing to silently fall back to ad-hoc signing. Repair the Keychain identity or explicitly set CLIPBOX_CODESIGN_IDENTITY=-.' >&2
    exit 1
else
    codesign_identity=-
fi

assert_replaceable_app() {
    app=$1
    if [ ! -e "$app" ]; then
        return
    fi
    plist="$app/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
        printf '%s\n' "Refusing to replace existing non-ClipBox path: $app" >&2
        exit 1
    fi
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)
    if [ "$existing_id" != "$bundle_id" ]; then
        printf '%s\n' "Refusing to replace app with bundle id '$existing_id': $app" >&2
        exit 1
    fi
}

cd "$project_root"

swift build -c release --product ClipBoxApp >&2
bin_dir=$(swift build -c release --show-bin-path)
source_binary="$bin_dir/ClipBoxApp"

if [ ! -x "$source_binary" ]; then
    printf '%s\n' "ClipBoxApp release binary was not produced at $source_binary" >&2
    exit 1
fi

assert_replaceable_app "$destination"
rm -rf "$destination"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"

cp "$source_binary" "$destination/Contents/MacOS/ClipBox"
chmod 755 "$destination/Contents/MacOS/ClipBox"
cp "$project_root/apps/macos/Info.plist" "$destination/Contents/Info.plist"
cp "$project_root/LICENSE" "$destination/Contents/Resources/LICENSE.txt"

/usr/bin/plutil -lint "$destination/Contents/Info.plist" >/dev/null
if [ "$codesign_identity" = '-' ]; then
    printf '%s\n' 'Signing ClipBox.app ad-hoc (no stable local signing identity found).' >&2
else
    printf 'Signing ClipBox.app with: %s\n' "$codesign_identity" >&2
fi
/usr/bin/codesign --force --sign "$codesign_identity" --timestamp=none "$destination"
/usr/bin/codesign --verify --strict "$destination"

printf '%s\n' "$destination"
