#!/usr/bin/env bash
# Score shipments with the RiskShip neural model and open one Linear issue per
# shipment whose predicted loss probability exceeds the threshold.
#
# Usage: evaluar_riesgo.sh [--threshold 0.65] [--dry-run] <predict_risk.py input>
#   <input> is any of:  shipment.json | - (stdin JSON) | --shipment-id ID [...] | --sample N [--seed S]
#   --dry-run  scores and prints the tickets it would create, without calling Linear.
#
# The model (model/riskship_rna_model.pickle) and the inference script live in this
# skill; the script declares its own dependencies inline and runs with `uv run`,
# so only `uv` is required on the host (first run downloads the environment).
#
# Env: LINEAR_API_KEY, LINEAR_TEAM_KEY (read from $HERMES_HOME/.env when not exported).
#      RISKSHIP_DATASET: optional parquet export, enables --shipment-id / --sample.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$(cd "$SKILL_DIR/../.." && pwd)}"
PREDICT="$SKILL_DIR/scripts/predict_risk.py"
LINEAR_SCRIPT="$HERMES_HOME/scripts/linear_create_issue.sh"
threshold=0.65
dry_run=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) threshold="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
[ ${#args[@]} -gt 0 ] || { echo "usage: evaluar_riesgo.sh [--threshold T] [--dry-run] <shipment.json | - | --shipment-id ID | --sample N>" >&2; exit 2; }

if [ -z "${LINEAR_API_KEY:-}" ] && [ -f "$HERMES_HOME/.env" ]; then
  set -a; # shellcheck disable=SC1091
  source "$HERMES_HOME/.env"; set +a
fi
[ -x "$LINEAR_SCRIPT" ] || { echo "missing $LINEAR_SCRIPT" >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required to run the model (https://docs.astral.sh/uv/)" >&2; exit 1; }
[ -f "$SKILL_DIR/model/riskship_rna_model.pickle" ] || { echo "missing $SKILL_DIR/model/riskship_rna_model.pickle" >&2; exit 1; }
dataset_args=()
[ -n "${RISKSHIP_DATASET:-}" ] && dataset_args=(--dataset "$RISKSHIP_DATASET")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

uv run --quiet "$PREDICT" --threshold "$threshold" ${dataset_args[@]+"${dataset_args[@]}"} "${args[@]}" > "$work/scores.json"

# Build one title/body pair per at-risk shipment with the system python3 (stdlib only).
# The body is written for the operations team: plain Spanish, no model internals.
WORK="$work" python3 - <<'PY'
import json, os
from datetime import datetime

work = os.environ["WORK"]
scores = json.load(open(os.path.join(work, "scores.json")))
threshold = scores["threshold"]
DAYS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
MONTHS = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
          "septiembre", "octubre", "noviembre", "diciembre"]


def num(value, decimals=0):
    """Spanish number format: thousands with '.', decimals with ','."""
    text = f"{float(value):,.{decimals}f}"
    return text.replace(",", "X").replace(".", ",").replace("X", ".")


def pct(value, decimals=0):
    return num(float(value) * 100, decimals) + " %"


def humanize(code):
    return str(code).replace("_", " ").strip().capitalize() if code else None


def when(raw):
    try:
        d = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return None
    return f"{DAYS[d.weekday()]} {d.day} de {MONTHS[d.month - 1]} de {d.year} a las {d:%H:%M}"


print("Evaluación RiskShip: {} envío(s), {} por encima del umbral de {}".format(
    scores["n_shipments"], scores["n_at_risk"], pct(threshold)))
for s in scores["shipments"]:
    print("- envío {}: probabilidad de pérdida {}{}".format(
        s["shipment_id"] or "sin ID", pct(s["loss_probability"], 1), "  -> RIESGO" if s["at_risk"] else ""))

n = 0
for s in scores["shipments"]:
    if not s["at_risk"]:
        continue
    n += 1
    sid = s["shipment_id"] or "sin ID"
    f = s["features"]
    p = s["loss_probability"]

    title = f"Envío {sid}: riesgo de pérdida {pct(p)}"

    facts = []
    picking = f.get("PICKING_TYPE")
    facility = f.get("SHP_LG_FACILITY_ID")
    if picking or facility:
        facts.append("Operación: " + ", ".join(x for x in [picking, f"instalación {facility}" if facility else None] if x))
    product = [humanize(f.get("DOM_DOMAIN_ID")), f.get("ORD_CATEGORY_NAME_L1"), f.get("BRAND_NAME")]
    if any(product):
        domain, category, brand = product
        text = domain or "sin dominio"
        if category:
            text += f" ({category})"
        if brand:
            text += f", marca {brand}"
        facts.append("Producto: " + text)
    package = []
    if f.get("CANTIDAD_ITEMS") is not None:
        qty = int(float(f["CANTIDAD_ITEMS"]))
        package.append(f"{qty} ítem" + ("s" if qty != 1 else ""))
    if f.get("PESO_TOTAL_KG") is not None:
        package.append(f"peso registrado {num(f['PESO_TOTAL_KG'])} kg")
    if f.get("DIM_MAX_CM") is not None:
        package.append(f"dimensión máxima {num(f['DIM_MAX_CM'])} cm")
    if f.get("VALOR_TOTAL_USD") is not None:
        package.append(f"valor USD {num(f['VALOR_TOTAL_USD'], 2)}")
    if package:
        facts.append("Paquete: " + ", ".join(package))
    if f.get("ES_BULKY") in (True, "true", "True"):
        facts.append("Voluminoso" + (f" (tipo {f['TIPO_BULKY']})" if f.get("TIPO_BULKY") else ""))
    elif f.get("ES_BULKY") is not None:
        facts.append("No voluminoso")
    if f.get("RATIO_SVC_MES_ANTERIOR") is not None:
        facts.append(f"Ratio de servicio del mes anterior: {pct(f['RATIO_SVC_MES_ANTERIOR'], 2)}")
    created = when(s.get("date_status_0"))
    if created:
        facts.append(f"Creado el {created}")

    body = "\n".join([
        f"El modelo de riesgo marcó el envío **{sid}** en el momento de su creación con una "
        f"probabilidad de pérdida del **{pct(p)}**, por encima del umbral de alerta del {pct(threshold)}. "
        "Conviene revisarlo antes del despacho.",
        "",
        "**Datos del envío**",
        "",
        *[f"- {fact}" for fact in facts],
        "",
        "**Cómo interpretar esta alerta**",
        "",
        "La cifra indica cuánto se parece este envío a los que se perdieron en el histórico; "
        "no señala una causa ni es una certeza. Está calculada sobre una muestra que "
        "sobrerrepresenta las pérdidas, así que en la operación real la proporción de alertas "
        "que terminan en pérdida es menor.",
        "",
        "_Alerta generada automáticamente por el agente RiskShip._",
    ])
    open(os.path.join(work, "%d.title" % n), "w").write(title)
    open(os.path.join(work, "%d.body" % n), "w").write(body)
PY

created=0
for title_file in "$work"/*.title; do
  [ -e "$title_file" ] || break
  body_file="${title_file%.title}.body"
  title="$(<"$title_file")"
  body="$(<"$body_file")"
  if [ "$dry_run" -eq 1 ]; then
    printf '\n[dry-run] ticket que se crearia:\n  titulo: %s\n%s\n' "$title" "$(sed 's/^/  /' "$body_file")"
  else
    bash "$LINEAR_SCRIPT" "$title" "$body"
    created=$((created + 1))
  fi
done
[ "$dry_run" -eq 1 ] || echo "tickets creados en Linear: $created"
