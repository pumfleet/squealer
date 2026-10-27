#!/bin/zsh
# Downloads the DB-IP Lite databases (CC BY 4.0, https://db-ip.com) and country centroids bundled with the app.
set -euo pipefail
cd "$(dirname "$0")/.."
destination=Squealer/Resources/GeoIP
mkdir -p "$destination"

fetch() {
    local name=$1
    for month in "$(date +%Y-%m)" "$(date -v-1m +%Y-%m)"; do
        if curl -fsSL "https://download.db-ip.com/free/dbip-$name-$month.mmdb.gz" -o "$destination/$name.mmdb.gz"; then
            gunzip -f "$destination/$name.mmdb.gz"
            mv "$destination/$name.mmdb" "$destination/dbip-$name.mmdb"
            echo "dbip-$name ($month)"
            return 0
        fi
    done
    echo "Couldn't download dbip-$name" >&2
    return 1
}

fetch country-lite
fetch asn-lite

curl -fsSL https://raw.githubusercontent.com/google/dspl/master/samples/google/canonical/countries.csv \
    | python3 -c '
import csv, json, sys
rows = csv.DictReader(sys.stdin)
print(json.dumps({r["country"]: [float(r["latitude"]), float(r["longitude"])] for r in rows if r["latitude"]}, separators=(",", ":")))
' > "$destination/country-centroids.json"
echo "country centroids"
