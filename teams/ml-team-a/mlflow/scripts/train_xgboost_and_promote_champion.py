#!/usr/bin/env python3
"""Train an XGBoost model, register it, and promote it to champion in MLflow.

Flow:
1) Train a small CPU-only XGBoost multiclass model.
2) Log model artifact to MLflow.
3) Create a model version from the run artifact.
4) Write KServe intent tags that point storageUri to MinIO (s3://...).
5) Point alias (default: champion) to the new version.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

try:
    import mlflow
    from mlflow import MlflowClient
except Exception as exc:  # pragma: no cover - dependency guard
    message = str(exc)
    if "Descriptors cannot be created directly" in message:
        raise SystemExit(
            "MLflow/protobuf dependency conflict detected.\n"
            "Fix in your current env:\n"
            "  pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' xgboost numpy\n"
            "Or temporary workaround for one run:\n"
            "  PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python python3 train_xgboost_and_promote_champion.py"
        ) from exc
    raise SystemExit(
        "Missing/invalid MLflow install. Install with:\n"
        "  pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' xgboost numpy\n"
        "or if you prefer conda:\n"
        "   conda install -c conda-forge mlflow=2.22.0 protobuf=3.20.3"
    ) from exc

try:
    import numpy as np
    import xgboost as xgb
except Exception as exc:  # pragma: no cover - runtime dependency guard
    raise SystemExit(
        "Missing dependency: xgboost/numpy. Install with:\n"
        "  pip install --upgrade xgboost numpy"
        "or if you prefer conda:\n"
        "   conda install -c conda-forge xgboost numpy"
    ) from exc


DEFAULT_TRACKING_URI = "http://mlflow.ml-team-a.local"
DEFAULT_REGISTERED_MODEL = "prod.ml-team-a.xgboost-synth"
DEFAULT_ALIAS = "champion"
DEFAULT_EXPERIMENT = "team-a-xgboost-training"
DEFAULT_KSERVE_NAME = "xgboost-synth-v1"
DEFAULT_MODEL_ARTIFACT_PATH = "model"
DEFAULT_MODEL_FILENAME = "model.bst"
DEFAULT_MINIO_ARTIFACT_ROOT = "s3://mlflow-ml-team-a/artifacts"

# Included here in the event MLFlow is ever made to require authentication
DEFAULT_TRACKING_USERNAME = ""
DEFAULT_TRACKING_PASSWORD = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train, register, and promote champion model in MLflow")
    parser.add_argument(
        "--tracking-uri",
        default=os.getenv("MLFLOW_TRACKING_URI", DEFAULT_TRACKING_URI),
        help="MLflow tracking URI",
    )
    parser.add_argument(
        "--registered-model",
        default=DEFAULT_REGISTERED_MODEL,
        help="Registered model name",
    )
    parser.add_argument(
        "--alias",
        default=DEFAULT_ALIAS,
        help="Model alias to set",
    )
    parser.add_argument(
        "--experiment",
        default=DEFAULT_EXPERIMENT,
        help="MLflow experiment name",
    )
    parser.add_argument(
        "--kserve-name",
        default=DEFAULT_KSERVE_NAME,
        help="InferenceService metadata.name to render",
    )
    parser.add_argument(
        "--model-artifact-path",
        default=DEFAULT_MODEL_ARTIFACT_PATH,
        help="Run artifact path for the logged model",
    )
    parser.add_argument(
        "--storage-uri",
        default="",
        help="Explicit KServe storageUri. If empty, computed from MinIO artifact root + run path.",
    )
    parser.add_argument(
        "--minio-artifact-root",
        default=os.getenv("MLFLOW_MINIO_ARTIFACT_ROOT", DEFAULT_MINIO_ARTIFACT_ROOT),
        help="Base MinIO artifact root (s3://...) used to build storageUri when --storage-uri is not set",
    )
    return parser.parse_args()


def build_inline_intent(kserve_name: str, storage_uri: str) -> dict:
    return {
        "metadata": {
            "name": kserve_name,
            "labels": {
                "owner.team": "ml-team-a",
                # Required by kserve-mlserver-custom runtime template.
                "modelClass": "mlserver_xgboost.XGBoostModel",
            },
            "annotations": {
                "autoscaling.knative.dev/min-scale": "0",
                "autoscaling.knative.dev/max-scale": "3",
                "autoscaling.knative.dev/target": "8",
            },
        },
        "spec": {
            "predictor": {
                "model": {
                    "modelFormat": {"name": "xgboost", "version": "1"},
                    "runtime": "kserve-mlserver-custom",
                    "protocolVersion": "v2",
                    "storageUri": storage_uri,
                }
            }
        },
    }


def make_synthetic_multiclass(seed: int = 42) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    x = rng.normal(0.0, 1.0, size=(480, 4)).astype(np.float32)
    w = np.array(
        [
            [1.7, -0.5, 0.8],
            [-1.1, 1.3, 0.2],
            [0.3, -1.6, 1.4],
            [1.0, 0.4, -1.2],
        ],
        dtype=np.float32,
    )
    noise = rng.normal(0.0, 0.35, size=(480, 3)).astype(np.float32)
    logits = x @ w + noise
    y = np.argmax(logits, axis=1).astype(np.int32)
    return x, y


def train_test_split(
    x: np.ndarray,
    y: np.ndarray,
    test_ratio: float = 0.2,
    seed: int = 42,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    indices = np.arange(x.shape[0])
    rng.shuffle(indices)
    split_at = int(x.shape[0] * (1.0 - test_ratio))
    train_idx = indices[:split_at]
    test_idx = indices[split_at:]
    return x[train_idx], x[test_idx], y[train_idx], y[test_idx]


def build_minio_storage_uri(
    minio_artifact_root: str,
    experiment_id: str,
    run_id: str,
    artifact_path: str,
) -> str:
    normalized_root = minio_artifact_root.rstrip("/")
    normalized_artifact_path = artifact_path.strip("/")
    if not normalized_root.startswith("s3://"):
        raise SystemExit(
            f"--minio-artifact-root must start with s3://, got: {minio_artifact_root!r}"
        )
    if not normalized_artifact_path:
        raise SystemExit("--model-artifact-path must not be empty")
    return f"{normalized_root}/{experiment_id}/{run_id}/artifacts/{normalized_artifact_path}"


def main() -> int:
    args = parse_args()

    if DEFAULT_TRACKING_USERNAME and "MLFLOW_TRACKING_USERNAME" not in os.environ:
        os.environ["MLFLOW_TRACKING_USERNAME"] = DEFAULT_TRACKING_USERNAME
    if DEFAULT_TRACKING_PASSWORD and "MLFLOW_TRACKING_PASSWORD" not in os.environ:
        os.environ["MLFLOW_TRACKING_PASSWORD"] = DEFAULT_TRACKING_PASSWORD

    mlflow.set_tracking_uri(args.tracking_uri)
    mlflow.set_experiment(args.experiment)

    x, y = make_synthetic_multiclass(seed=42)
    x_train, x_test, y_train, y_test = train_test_split(x, y, test_ratio=0.2, seed=42)

    dtrain = xgb.DMatrix(x_train, label=y_train)
    dtest = xgb.DMatrix(x_test, label=y_test)

    params = {
        "objective": "multi:softprob",
        "num_class": 3,
        "eval_metric": "mlogloss",
        "eta": 0.08,
        "max_depth": 5,
        "subsample": 0.9,
        "colsample_bytree": 0.9,
        "seed": 42,
    }

    booster = xgb.train(
        params=params,
        dtrain=dtrain,
        num_boost_round=90,
        evals=[(dtrain, "train"), (dtest, "test")],
        verbose_eval=False,
    )
    proba = booster.predict(dtest)
    preds = np.argmax(proba, axis=1)
    accuracy = float((preds == y_test).mean())

    with mlflow.start_run(run_name="xgboost-synth-train") as run:
        run_id = run.info.run_id
        experiment_id = str(run.info.experiment_id)
        artifact_path = args.model_artifact_path.strip("/")

        mlflow.log_param("model_type", "XGBoostBooster")
        mlflow.log_param("dataset", "synthetic_multiclass")
        mlflow.log_param("features", int(x.shape[1]))
        mlflow.log_param("train_rows", int(x_train.shape[0]))
        mlflow.log_param("test_rows", int(x_test.shape[0]))
        mlflow.log_metric("accuracy", accuracy)
        # Log native XGBoost artifact (not MLflow flavor bundle) so mlserver_xgboost
        # can load it directly from storageUri.
        with tempfile.TemporaryDirectory() as tmpdir:
            model_path = os.path.join(tmpdir, DEFAULT_MODEL_FILENAME)
            booster.save_model(model_path)
            mlflow.log_artifact(model_path, artifact_path=artifact_path)

    client = MlflowClient(tracking_uri=args.tracking_uri)

    try:
        client.create_registered_model(args.registered_model)
    except Exception:
        pass

    mv = client.create_model_version(
        name=args.registered_model,
        source=f"runs:/{run_id}/{artifact_path}/{DEFAULT_MODEL_FILENAME}",
        run_id=run_id,
    )
    version = str(mv.version)

    if args.storage_uri.strip():
        storage_uri = args.storage_uri.strip()
    else:
        storage_uri = build_minio_storage_uri(
            minio_artifact_root=args.minio_artifact_root,
            experiment_id=experiment_id,
            run_id=run_id,
            artifact_path=artifact_path,
        )

    intent = build_inline_intent(args.kserve_name, storage_uri)

    client.set_model_version_tag(args.registered_model, version, "kserve.intent.mode", "inline")
    client.set_model_version_tag(
        args.registered_model,
        version,
        "kserve.intent.payload",
        json.dumps(intent, separators=(",", ":")),
    )
    client.set_registered_model_alias(args.registered_model, args.alias, version)

    print(
        json.dumps(
            {
                "tracking_uri": args.tracking_uri,
                "registered_model": args.registered_model,
                "version": version,
                "alias": args.alias,
                "accuracy": accuracy,
                "storage_uri": storage_uri,
                "model_format": "xgboost",
                "runtime": "kserve-mlserver-custom",
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
