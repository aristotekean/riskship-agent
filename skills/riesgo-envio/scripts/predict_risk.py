# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#   "autogluon-tabular[fastai]==1.6.3",
#   "fastai==2.8.7",
#   "torch==2.10.0",
#   "pandas==2.3.3",
#   "numpy==2.5.3",
#   "scikit-learn==1.9.1",
# ]
# ///
"""Score shipments with the RiskShip model shipped in this skill.

Standalone copy of ``predict_risk.py`` from the riskship-rna project: it needs no
checkout of that project, only ``uv`` (the dependencies above are the exact
versions the pickle was written with, see ``../model/riskship_rna_model.json``).

    uv run predict_risk.py shipment.json          # JSON object or list of objects
    echo '{...}' | uv run predict_risk.py -        # stdin
    uv run predict_risk.py --dataset /path/dataset.parquet --shipment-id 46411999224
    uv run predict_risk.py --dataset /path/dataset.parquet --sample 3

Prints one JSON document with the loss probability per shipment and ``at_risk``
against ``--threshold`` (default 0.65).
"""

from __future__ import annotations

import argparse
import json
import pickle
import sys
import warnings
from pathlib import Path

import pandas as pd

warnings.filterwarnings("ignore")

SKILL_DIR = Path(__file__).resolve().parent.parent
MODEL_PATH = SKILL_DIR / "model" / "riskship_rna_model.pickle"
DEFAULT_THRESHOLD = 0.65
ID_COLUMN = "SHIPMENT_ID"
DATE_COLUMN = "date_status_0"
# Same names and order as the training notebook: the model learned these values.
DAY_NAMES = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
ARTIFACT_COLUMNS = ["PESO_TOTAL_KG", "DIM_MAX_CM", "VALOR_TOTAL_USD", "CANTIDAD_ITEMS", DATE_COLUMN]


def prepare_features(raw: pd.DataFrame) -> pd.DataFrame:
    """Inference-time part of the notebook's preprocess: the two derived features."""
    frame = raw.copy()
    frame["TIPO_BULKY"] = frame["TIPO_BULKY"].fillna("NONE")
    frame["day_of_week"] = pd.Categorical(
        pd.to_datetime(frame[DATE_COLUMN]).dt.dayofweek.map(dict(enumerate(DAY_NAMES))),
        categories=DAY_NAMES,
        ordered=True,
    )
    return frame


def load_predictor(path: Path):
    if not path.exists():
        sys.exit(f"model not found at {path}")
    with path.open("rb") as f:
        return pickle.load(f)


def read_shipments(source: str) -> pd.DataFrame:
    text = sys.stdin.read() if source == "-" else Path(source).read_text()
    payload = json.loads(text)
    rows = payload if isinstance(payload, list) else [payload]
    if not rows:
        sys.exit("no shipments in input")
    return pd.DataFrame(rows)


def rows_from_dataset(dataset: Path, shipment_ids: list[str] | None, sample: int | None, seed: int | None) -> pd.DataFrame:
    raw = pd.read_parquet(dataset)
    if shipment_ids:
        rows = raw[raw[ID_COLUMN].astype(str).isin(shipment_ids)]
        if rows.empty:
            sys.exit(f"no rows for SHIPMENT_ID in {shipment_ids}")
        return rows
    return raw.dropna(subset=ARTIFACT_COLUMNS).sample(n=sample, random_state=seed)


def score(predictor, shipments: pd.DataFrame, threshold: float) -> dict:
    features = predictor.features()
    missing = [c for c in features if c not in shipments.columns and c != "day_of_week"]
    if DATE_COLUMN not in shipments.columns:
        missing.append(DATE_COLUMN)
    if missing:
        sys.exit(f"input is missing columns the model needs: {missing}")
    prepared = prepare_features(shipments)
    probabilities = predictor.predict_proba(prepared[features], as_multiclass=False).to_numpy()
    results = []
    for (_, row), p in zip(shipments.iterrows(), probabilities):
        results.append({
            "shipment_id": None if ID_COLUMN not in row or pd.isna(row[ID_COLUMN]) else str(row[ID_COLUMN]),
            "loss_probability": round(float(p), 4),
            "at_risk": bool(p > threshold),
            "actual_is_lost": None if "is_lost" not in row or pd.isna(row["is_lost"]) else int(row["is_lost"]),
            "features": {c: (None if pd.isna(row[c]) else row[c]) for c in features if c in row.index},
        })
    return {
        "threshold": threshold,
        "model": str(MODEL_PATH.relative_to(SKILL_DIR)),
        "n_shipments": len(results),
        "n_at_risk": sum(r["at_risk"] for r in results),
        "any_at_risk": any(r["at_risk"] for r in results),
        "shipments": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("source", nargs="?", help="JSON file with shipment(s), or '-' for stdin")
    parser.add_argument("--dataset", type=Path, help="parquet export to take rows from (for --shipment-id / --sample)")
    parser.add_argument("--shipment-id", action="append", help="score this SHIPMENT_ID from --dataset (repeatable)")
    parser.add_argument("--sample", type=int, help="score N random shipments from --dataset (demo)")
    parser.add_argument("--seed", type=int, default=None, help="random seed for --sample")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD, help=f"risk threshold (default {DEFAULT_THRESHOLD})")
    parser.add_argument("--model", type=Path, default=MODEL_PATH)
    args = parser.parse_args()

    if args.source:
        shipments = read_shipments(args.source)
    elif args.shipment_id or args.sample:
        if not args.dataset:
            parser.error("--shipment-id and --sample need --dataset <parquet>")
        shipments = rows_from_dataset(args.dataset, args.shipment_id, args.sample, args.seed)
    else:
        parser.error("give a JSON source, or --dataset with --shipment-id / --sample")

    predictor = load_predictor(args.model)
    print(json.dumps(score(predictor, shipments, args.threshold), ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    main()
