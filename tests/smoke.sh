#!/usr/bin/bash
# Live: one request per subcommand for two places, a big city and a small
# town, each answer parsed by the same code the widget runs. A handful of
# requests; run it by hand, not in a loop.
set -u
cd "$(dirname "$0")/.."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

run() { printf '%s\n' "$2" | bin/inair-fetch "$1"; }

# accept SOURCE STATE OP CONTEXT: parse $tmp the way the widget would and
# print the observation's PM2.5, or the status when there is none.
accept() {
  node -e '
    const { Sources, Model } = require("./tests/load")
    const fs = require("fs")
    const [id, state, op, ctx] = process.argv.slice(1, 5).map(JSON.parse)
    const r = Sources.accept(id, state, op, fs.readFileSync(process.argv[5], "utf8"), ctx, Date.now())
    if (r.observation) console.log("ok   " + id + ": " + (Model.value(r.observation.readings, "pm25") ?? r.observation.level))
    else if (r.status) console.log("note " + id + ": " + r.status)
    else if (r.again) console.log("ok   " + id + ": next step")
    else { console.log("FAIL " + id); process.exit(1) }
  ' "\"$1\"" "$2" "\"$3\"" "$4" "$tmp"
}

fails=0
for place in "50.060 19.940" "53.360 20.427"; do
  lat=${place% *}; lon=${place#* }
  ctx="{\"place\":{\"name\":\"x\",\"latitude\":$lat,\"longitude\":$lon},\"locker\":\"\"}"
  echo "== $place"
  box=$(node -e "const {Sources}=require('./tests/load');console.log(Sources.plan('sensorcommunity',{radius:2},$ctx,Date.now()).input)")
  run sc-box "$box" > "$tmp" && accept sensorcommunity '{"radius":2}' sc-box "$ctx" || fails=$((fails + 1))
  run om-current "$place" > "$tmp" && accept openmeteo '{}' om-current "$ctx" || fails=$((fails + 1))
  run nearby "$place" > "$tmp" && accept inpost '{}' nearby "$ctx" || fails=$((fails + 1))
  bin/inair-fetch gios-stations </dev/null > "$tmp" && accept gios '{}' gios-stations "$ctx" || fails=$((fails + 1))
done
run gios-index 400 > "$tmp" && echo "ok   gios-index 400: $(head -c 60 "$tmp")" || fails=$((fails + 1))
run geocode "Bielsko-Biała" > "$tmp" && node -e '
  const {Sources}=require("./tests/load")
  const p=Sources.parsePlaces(require("fs").readFileSync(process.argv[1],"utf8"))
  if(!p.length) process.exit(1); console.log("ok   geocode: " + p[0].name + " — " + p[0].detail)' "$tmp" || fails=$((fails + 1))

[ "$fails" -eq 0 ] && echo "smoke done" || { echo "$fails failed"; exit 1; }
