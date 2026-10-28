#!/bin/zsh
# Builds a Developer ID release: archive, re-sign for Developer ID, notarize, staple, DMG and (when Sparkle is
# configured) an appcast.
#
# Xcode can't export this app for Developer ID by itself: the Network Extension entitlement must be the
# -systemextension form there, development profiles only grant the plain form, and export doesn't convert
# between them. So the archive is signed for development and re-signed here, inside-out, with the Developer ID
# profiles Xcode manages ("Mac Team Direct Provisioning Profile: …"; run an export once in Xcode, or let
# `xcodebuild -exportArchive -allowProvisioningUpdates` create them).
#
# One-time setup for notarization:
#   xcrun notarytool store-credentials squealer --apple-id <id> --team-id U6P67B4375
# Sparkle signs the appcast with the EdDSA key generate_keys stored in the login keychain. Its public half is
# SQUEALER_SPARKLE_PUBLIC_KEY in project.yml; without the private key, installed copies can't be updated.
#
# --publish creates the GitHub release v<version> with the DMG and appcast.xml. The app's feed is the appcast of the
# latest release, so publishing is what ships the update.
#
# Usage: scripts/release.sh <version> [build] [--skip-notarize] [--publish]
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: scripts/release.sh <version> [build] [--skip-notarize] [--publish]"
notarize=true
publish=false
positional=()
for argument in "$@"; do
    case $argument in
        --skip-notarize) notarize=false ;;
        --publish) publish=true ;;
        -*) echo "$usage" >&2; exit 1 ;;
        *) positional+=("$argument") ;;
    esac
done
version=${positional[1]:?$usage}
build=${positional[2]:-$(date +%Y%m%d%H%M)}
repository=pumfleet/squealer
if $publish; then
    $notarize || { echo "--publish requires notarization." >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes before publishing." >&2; exit 1; }
    git fetch --quiet origin main
    git merge-base --is-ancestor HEAD origin/main || { echo "Push HEAD to origin/main before publishing." >&2; exit 1; }
fi
team=U6P67B4375
identity="Developer ID Application: Fusial LLC ($team)"
out=build/release/$version
rm -rf "$out" && mkdir -p "$out"

[[ -f Squealer/Resources/GeoIP/dbip-country-lite.mmdb ]] || scripts/fetch-geoip.sh
xcodegen generate --quiet

echo "Archiving…"
xcodebuild -project Squealer.xcodeproj -scheme Squealer -configuration Release \
    -archivePath "$out/Squealer.xcarchive" -derivedDataPath build/DerivedDataRelease -allowProvisioningUpdates \
    MARKETING_VERSION="$version" SQUEALER_BUILD="$build" archive > "$out/archive.log" 2>&1 \
    || { grep -E "error:" "$out/archive.log" >&2; exit 1; }

app="$out/Squealer.app"
ditto "$out/Squealer.xcarchive/Products/Applications/Squealer.app" "$app"
extension="$app/Contents/Library/SystemExtensions/com.fusial.squealer.extension.systemextension"

profile() {
    local name="Mac Team Direct Provisioning Profile: $1"
    for file in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile(N) ~/Library/MobileDevice/Provisioning\ Profiles/*.provisionprofile(N); do
        if [[ "$(security cms -D -i "$file" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" == "$name" ]]; then
            echo "$file"
            return 0
        fi
    done
    echo "Missing provisioning profile \"$name\". Export once with xcodebuild -exportArchive -allowProvisioningUpdates to create it." >&2
    return 1
}

# Developer ID entitlements: the source file with build settings resolved, the -systemextension form, and the
# identifiers the provisioning profile ties them to.
entitlements() {
    local source=$1 bundle_id=$2 destination=$3
    sed -e "s/\$(SQUEALER_NE_FILTER)/content-filter-provider-systemextension/" \
        -e "s/\$(TeamIdentifierPrefix)/$team./" "$source" > "$destination"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team.$bundle_id" "$destination"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$destination"
}

echo "Signing for Developer ID…"
entitlements SquealerExtension/SquealerExtension.entitlements com.fusial.squealer.extension "$out/extension.entitlements"
entitlements Squealer/Squealer.entitlements com.fusial.squealer "$out/app.entitlements"
cp "$(profile com.fusial.squealer.extension)" "$extension/Contents/embedded.provisionprofile"
cp "$(profile com.fusial.squealer)" "$app/Contents/embedded.provisionprofile"

# Bare executables too, like Sparkle's Autoupdate; ones inside nested bundles are signed with their bundle.
frameworks="$app/Contents/Frameworks"
find "$frameworks" -depth \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.app" \
    -o \( -type f -perm +111 ! -path "$frameworks/*.app/*" ! -path "$frameworks/*.xpc/*" \) \) 2>/dev/null \
    | while read -r item; do codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$item"; done
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Helpers/squealer"
codesign --force --options runtime --timestamp --sign "$identity" --entitlements "$out/extension.entitlements" "$extension"
codesign --force --options runtime --timestamp --sign "$identity" --entitlements "$out/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

# notarytool exits 0 even when Apple rejects the upload, so check the status and print Apple's reasons.
submit() {
    local output
    output=$(xcrun notarytool submit "$1" --keychain-profile squealer --wait 2>&1) || { echo "$output" >&2; return 1; }
    if ! grep -q "status: Accepted" <<< "$output"; then
        echo "$output" >&2
        xcrun notarytool log "$(grep -oE "id: [0-9a-f-]{36}" <<< "$output" | head -1 | cut -c5-)" --keychain-profile squealer >&2
        return 1
    fi
}

if $notarize; then
    echo "Notarizing…"
    ditto -c -k --keepParent "$app" "$out/Squealer.zip"
    submit "$out/Squealer.zip"
    xcrun stapler staple "$app"
fi

echo "Building DMG…"
dmg="$out/Squealer-$version.dmg"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Squealer.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Squealer $version" -srcfolder "$staging" -ov -format UDZO "$dmg" > /dev/null
codesign --sign "$identity" --timestamp "$dmg"
if $notarize; then
    submit "$dmg"
    xcrun stapler staple "$dmg"
fi

if $notarize; then
    echo "Generating appcast…"
    # Only the DMG goes in: generate_appcast would also pick up the notarization zip.
    updates="$out/updates"
    mkdir -p "$updates"
    cp "$dmg" "$updates/"
    build/DerivedDataRelease/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast "$updates" \
        --download-url-prefix "https://github.com/$repository/releases/download/v$version/"
fi

if $publish; then
    echo "Publishing v$version…"
    gh release create "v$version" "$dmg" "$updates/appcast.xml" --repo "$repository" \
        --target "$(git rev-parse HEAD)" --title "Squealer $version" --generate-notes
fi
echo "Release ready: $dmg"
