#!/usr/bin/bash
# Offline: what each subcommand would fetch, and what it refuses. Nothing here
# touches the network; INAIR_DRY_RUN makes the helper print the URL instead.
set -u
cd "$(dirname "$0")/.."
fails=0

expect_url() {
  local name="$1" input="$2" want="$3" got
  got=$(printf '%s\n' "$input" | INAIR_DRY_RUN=1 bin/inair-fetch "$name" 2>&1)
  if [ "$got" = "$want" ]; then echo "ok   $name <$input>"
  else echo "FAIL $name <$input>"; echo "  want $want"; echo "  got  $got"; fails=$((fails + 1)); fi
}

expect_refusal() {
  local name="$1" input="$2"
  if printf '%s\n' "$input" | INAIR_DRY_RUN=1 bin/inair-fetch "$name" >/dev/null 2>&1; then
    echo "FAIL $name accepted <$input>"; fails=$((fails + 1))
  else echo "ok   $name refused <$input>"; fi
}

expect_url sc-box "50.042 19.909 50.078 19.971" \
  "https://data.sensor.community/airrohr/v1/filter/box=50.042,19.909,50.078,19.971"
expect_url gios-sensors "400" "https://api.gios.gov.pl/pjp-api/v1/rest/station/sensors/400"
expect_url gios-data "2752" "https://api.gios.gov.pl/pjp-api/v1/rest/data/getData/2752"
expect_url gios-index "400" "https://api.gios.gov.pl/pjp-api/v1/rest/aqindex/getIndex/400"
expect_url om-current "50.060 19.940" \
  "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=50.060&longitude=19.940&current=pm10,pm2_5,european_aqi&timezone=auto"
expect_url geocode "Nowy Sącz" \
  "https://geocoding-api.open-meteo.com/v1/search?name=Nowy%20S%C4%85cz&count=5&language=pl&format=json"
expect_url geocode "Bielsko-Biała" \
  "https://geocoding-api.open-meteo.com/v1/search?name=Bielsko%2DBia%C5%82a&count=5&language=pl&format=json"

got=$(INAIR_DRY_RUN=1 bin/inair-fetch gios-stations </dev/null 2>&1)
[ "$got" = "https://api.gios.gov.pl/pjp-api/v1/rest/station/findAll?size=500" ] \
  && echo "ok   gios-stations without stdin" || { echo "FAIL gios-stations: $got"; fails=$((fails + 1)); }

expect_refusal sc-box "50.04 19.90 50.07"
expect_refusal sc-box "50.04 19.90 50.07 19.97\"; url = \"https://evil.example"
expect_refusal sc-box "91x 19.90 50.07 19.97"
expect_refusal gios-sensors "400/../../x"
expect_refusal gios-data "12a"
expect_refusal gios-index ""
expect_refusal om-current "50.06"
expect_refusal geocode ""
expect_refusal geocode "$(printf 'x%.0s' {1..130})"
expect_refusal nope "x"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
