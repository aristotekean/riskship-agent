#!/usr/bin/env bash
# Cron source for the riesgo-envio skill: pull the shipment rows inserted in Neon
# since the last run, score one row per shipment with the model and open Linear
# issues for the ones above the threshold. Stdout is injected into the agent prompt.
#
# Neon is queried over its serverless HTTP SQL endpoint (https://<host>/sql with
# the Neon-Connection-String header): no psql or Postgres driver needed.
# The watermark is the last processed `id` (bigserial) of the shipments table,
# kept in $HERMES_HOME/cron/riesgo_envio.watermark. On the first run the
# watermark is set to the current max id and nothing is scored, so a freshly
# bulk-loaded history never floods Linear with tickets.
#
# Env: NEON_READONLY_URL (required; read from $HERMES_HOME/.env when not exported)
#      RISKSHIP_THRESHOLD  risk threshold passed to the skill (default: 0.65)
#      RISKSHIP_LIMIT      max rows per run (default: 200)
#      RISKSHIP_DRY_RUN=1  score only, never call Linear
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILL="$HERMES_HOME/skills/riesgo-envio/scripts/evaluar_riesgo.sh"
WATERMARK="$HERMES_HOME/cron/riesgo_envio.watermark"
THRESHOLD="${RISKSHIP_THRESHOLD:-0.65}"
LIMIT="${RISKSHIP_LIMIT:-200}"
FEATURES='"SHIPMENT_ID", "PICKING_TYPE", "SHP_LG_FACILITY_ID", "DOM_DOMAIN_ID", "ORD_CATEGORY_NAME_L1",
  "BRAND_NAME", "TIPO_BULKY", "PESO_TOTAL_KG", "DIM_MAX_CM", "VALOR_TOTAL_USD", "CANTIDAD_ITEMS",
  "RATIO_SVC_MES_ANTERIOR", "ES_BULKY", "date_status_0"'

if [ -z "${NEON_READONLY_URL:-}" ] && [ -f "$HERMES_HOME/.env" ]; then
  set -a; # shellcheck disable=SC1091
  source "$HERMES_HOME/.env"; set +a
fi
: "${NEON_READONLY_URL:?NEON_READONLY_URL is not set}"
[ -x "$SKILL" ] || { echo "missing $SKILL" >&2; exit 1; }

host="$(python3 -c 'import sys; from urllib.parse import urlparse; print(urlparse(sys.argv[1]).hostname)' "$NEON_READONLY_URL")"
endpoint="https://$host/sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# neon_sql <query> <params-json>  -> writes $work/response.json
neon_sql() {
  QUERY="$1" PARAMS="$2" python3 -c 'import json,os; print(json.dumps({"query":os.environ["QUERY"],"params":json.loads(os.environ["PARAMS"])}))' \
    > "$work/request.json"
  if ! curl -fsS --max-time 60 "$endpoint" \
       -H "Neon-Connection-String: $NEON_READONLY_URL" \
       -H 'Content-Type: application/json' \
       --data-binary @"$work/request.json" > "$work/response.json" 2> "$work/curl.err"; then
    echo "ERROR: Neon query failed: $(cat "$work/curl.err") $(head -c 500 "$work/response.json" 2>/dev/null || true)" >&2
    exit 1
  fi
}

mkdir -p "$(dirname "$WATERMARK")"
if [ ! -s "$WATERMARK" ]; then
  neon_sql 'SELECT coalesce(max(id), 0) AS max_id, count(*) AS n FROM shipments' '[]'
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["rows"][0]; print(int(r["max_id"])); print(int(r["n"]), file=sys.stderr)' \
    "$work/response.json" > "$WATERMARK" 2> "$work/n.txt"
  echo "Primera corrida: marca de agua inicializada en id=$(cat "$WATERMARK"). Las $(cat "$work/n.txt") filas ya cargadas en Neon no se evaluan; solo se evaluaran los envios insertados a partir de ahora."
  exit 0
fi
since="$(cat "$WATERMARK")"

neon_sql "SELECT id, $FEATURES FROM shipments WHERE id > \$1::bigint ORDER BY id LIMIT $LIMIT" "[\"$since\"]"

# One row per shipment (rows are items), without created_at/id -> shipments.json
new_watermark="$(WORK="$work" python3 - <<'PY'
import json, os, sys
work = os.environ["WORK"]
data = json.load(open(os.path.join(work, "response.json")))
if "rows" not in data:
    sys.exit("unexpected Neon response: " + json.dumps(data)[:500])
rows = data["rows"]
seen, shipments = set(), []
for r in rows:
    sid = r.get("SHIPMENT_ID")
    if sid in seen:
        continue
    seen.add(sid)
    shipments.append({k: v for k, v in r.items() if k != "id"})
json.dump(shipments, open(os.path.join(work, "shipments.json"), "w"), ensure_ascii=False)
print(max((int(r["id"]) for r in rows), default=0))
print(f"{len(rows)} {len(shipments)}", file=sys.stderr)
PY
)" 2> "$work/counts.txt"
read -r n_rows n_shipments < "$work/counts.txt"

echo "Ventana consultada: filas de shipments con id > $since (maximo $LIMIT por corrida)."
if [ "$n_rows" -eq 0 ]; then
  echo "No hay envios nuevos en Neon desde la ultima corrida. Nada que evaluar."
  exit 0
fi
echo "Filas nuevas: $n_rows; envios distintos: $n_shipments."

dry=()
[ "${RISKSHIP_DRY_RUN:-0}" = "1" ] && dry=(--dry-run)
bash "$SKILL" --threshold "$THRESHOLD" ${dry[@]+"${dry[@]}"} "$work/shipments.json"

printf '%s' "$new_watermark" > "$WATERMARK"
echo "Marca de agua actualizada a id=$new_watermark."
