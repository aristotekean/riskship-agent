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
MODEL_META="$SKILL_DIR/model/riskship_rna_model.json"
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
MODEL_META="$MODEL_META" WORK="$work" python3 - <<'PY'
import json, os
work = os.environ["WORK"]
scores = json.load(open(os.path.join(work, "scores.json")))
try:
    meta = json.load(open(os.environ["MODEL_META"]))
except OSError:
    meta = {}
threshold = scores["threshold"]
print("Evaluacion RiskShip: {} envio(s), {} por encima del umbral {:.0%}".format(
    scores["n_shipments"], scores["n_at_risk"], threshold))
for s in scores["shipments"]:
    sid = s["shipment_id"] or "sin ID"
    print("- envio {}: probabilidad de perdida {:.1%}{}".format(
        sid, s["loss_probability"], "  -> RIESGO" if s["at_risk"] else ""))
n = 0
for s in scores["shipments"]:
    if not s["at_risk"]:
        continue
    n += 1
    sid = s["shipment_id"] or "sin ID"
    p = s["loss_probability"]
    title = "Riesgo de perdida {:.0%} - envio {}".format(p, sid)
    rows = "\n".join("| {} | {} |".format(k, "" if v is None else v) for k, v in s["features"].items())
    body = "\n".join([
        "## Lo que detecto el modelo",
        "",
        "- Envio: `{}`".format(sid),
        "- Probabilidad de perdida estimada al momento de la creacion: **{:.1%}** (umbral de alerta: {:.0%}).".format(p, threshold),
        "- Modelo: red neuronal RiskShip (`{}`, semilla {}, PR-AUC de validacion {:.4f}).".format(
            scores.get("model", "?"), meta.get("seed", "?"), float(meta.get("validation_pr_auc", float("nan")))),
        "",
        "## Lo que se sabe del envio",
        "",
        "| Variable | Valor |",
        "|---|---|",
        rows,
        "",
        "## Como leer esta alerta",
        "",
        "La probabilidad esta en la escala de la muestra de entrenamiento, que sobrerrepresenta las perdidas; "
        "en operacion real la proporcion de alertas que terminan en perdida es menor. "
        "El modelo no explica la causa: indica que el envio se parece a los que se perdieron. "
        "Esta alerta fue generada automaticamente por el agente RiskShip.",
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
