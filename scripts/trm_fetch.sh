#!/usr/bin/env bash
# Fetch the official USD/COP exchange rate (TRM) published by the Colombian
# government via datos.gov.co, with a market-rate fallback. Prints a compact,
# machine-readable summary on stdout for the cron agent prompt.
set -euo pipefail

TRM_URL='https://www.datos.gov.co/resource/32sa-8pi3.json?$limit=1&$order=vigenciadesde%20DESC'
FALLBACK_URL='https://open.er-api.com/v6/latest/USD'

json="$(curl -fsS --max-time 20 "$TRM_URL" || true)"
valor="$(printf '%s' "$json" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)[0]; print(d["valor"], d["vigenciadesde"][:10], d["vigenciahasta"][:10])
except Exception:
    pass' 2>/dev/null || true)"

if [ -n "$valor" ]; then
  read -r value from until <<<"$valor"
  echo "source=datos.gov.co (TRM oficial, Superfinanciera)"
  echo "usd_cop=$value"
  echo "valid_from=$from"
  echo "valid_until=$until"
  exit 0
fi

fb="$(curl -fsS --max-time 20 "$FALLBACK_URL" | python3 -c 'import sys,json
d=json.load(sys.stdin); print(d["rates"]["COP"], d["time_last_update_utc"])')"
read -r value updated <<<"$fb"
echo "source=open.er-api.com (tasa de mercado, fallback)"
echo "usd_cop=$value"
echo "updated_utc=$updated"
