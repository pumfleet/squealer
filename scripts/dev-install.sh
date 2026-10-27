#!/bin/zsh
# Builds a signed Debug build, installs it in /Applications (system extensions only activate from there) and
# relaunches it. The extension's build number only changes when its code does: every change makes the app
# replace the running extension, and rapid back-to-back replacements can leave its XPC service unregistered
# until a reboot.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

app_build=$(date +%Y%m%d%H%M%S)
extension_hash=$(find SquealerExtension Packages/SquealerKit/Sources project.yml -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-12)
if [[ -f build/extension.hash && $(cat build/extension.hash) == "$extension_hash" && -f build/extension.build ]]; then
    extension_build=$(cat build/extension.build)
else
    extension_build=$app_build
fi

[[ -f Squealer/Resources/GeoIP/dbip-country-lite.mmdb ]] || scripts/fetch-geoip.sh
xcodegen generate --quiet
xcodebuild -project Squealer.xcodeproj -scheme Squealer -configuration Debug \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates \
    SQUEALER_BUILD="$app_build" SQUEALER_EXTENSION_BUILD="$extension_build" build > build/xcodebuild.log 2>&1 \
    || { grep -E "error:" build/xcodebuild.log >&2; echo "Build failed; see build/xcodebuild.log" >&2; exit 1; }

product=build/DerivedData/Build/Products/Debug/Squealer.app
echo "$extension_hash" > build/extension.hash
echo "$extension_build" > build/extension.build

pkill -x Squealer 2>/dev/null || true
rm -rf /Applications/Squealer.app
ditto "$product" /Applications/Squealer.app
open /Applications/Squealer.app --args "$@"
echo "Installed app $app_build, extension $extension_build"

