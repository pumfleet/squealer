#!/bin/zsh
# Adds new user-facing strings from the last Debug build to the string catalog (Xcode only does this in the IDE).
# New strings show up untranslated; translate them in Localizable.xcstrings before releasing.
set -euo pipefail
cd "$(dirname "$0")/.."
data=(build/DerivedData/Build/Intermediates.noindex/Squealer.build/Debug/Squealer.build/Objects-normal/*/*.stringsdata(N))
(( ${#data} )) || { echo "Build the app first (scripts/dev-install.sh or xcodebuild)." >&2; exit 1; }
args=()
for file in $data; do args+=(--stringsdata "$file"); done
xcrun xcstringstool sync Squealer/Resources/Localizable.xcstrings "${args[@]}"
python3 - <<'PY'
import json
catalog = json.load(open("Squealer/Resources/Localizable.xcstrings"))
languages = ["de", "fr", "es", "ja", "zh-Hans"]
missing = {l: sum(1 for k, v in catalog["strings"].items() if v.get("shouldTranslate", True) and l not in v.get("localizations", {})) for l in languages}
print("Untranslated:", missing)
PY
