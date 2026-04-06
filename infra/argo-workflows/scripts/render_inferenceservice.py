#!/usr/bin/env python3
"""Render tenant-safe KServe InferenceService manifest from intent payload."""

from __future__ import annotations

import argparse
import base64
import copy
import json
import pathlib
import sys
import traceback
from typing import Any, Dict

LEGACY_RUNTIME_NAME = "kserve-mlserver"
CANONICAL_RUNTIME_NAME = "kserve-mlserver-custom"
S3_STORAGE_SECRET_ANNOTATION = "serving.kserve.io/storageSecretName"
S3_STORAGE_SERVICE_ACCOUNT = "kserve-storage-sa"


def _write_output(path: pathlib.Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def _decode_intent(intent_json_b64: str) -> Dict[str, Any]:
    raw = base64.b64decode(intent_json_b64.encode("utf-8")).decode("utf-8")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("intent is not a JSON object")
    return data


def _validate_intent(intent: Dict[str, Any]) -> None:
    metadata = intent.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError("intent.metadata must be an object")

    name = metadata.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("intent.metadata.name is required")

    spec = intent.get("spec")
    if not isinstance(spec, dict):
        raise ValueError("intent.spec must be an object")


def _render_manifest(
    intent: Dict[str, Any],
    tenant: str,
    namespace: str,
    registered_model: str,
    alias: str,
    resolved_version: str,
    intent_hash: str,
    storage_secret_name: str,
) -> Dict[str, Any]:
    rendered = copy.deepcopy(intent)
    rendered["apiVersion"] = "serving.kserve.io/v1beta1"
    rendered["kind"] = "InferenceService"

    metadata = rendered.setdefault("metadata", {})
    metadata["namespace"] = namespace

    labels = metadata.setdefault("labels", {})
    if not isinstance(labels, dict):
        labels = {}
        metadata["labels"] = labels

    annotations = metadata.setdefault("annotations", {})
    if not isinstance(annotations, dict):
        annotations = {}
        metadata["annotations"] = annotations

    labels["platform.ai-ml/tenant"] = tenant
    labels["platform.ai-ml/alias"] = alias
    if resolved_version:
        labels["platform.ai-ml/model-version"] = str(resolved_version)

    annotations["platform.ai-ml/registered-model"] = registered_model
    if intent_hash:
        annotations["platform.ai-ml/intent-hash"] = intent_hash

    # Backward compatibility for existing MLflow intent payloads that still
    # reference the legacy runtime name.
    predictor = rendered.get("spec", {}).get("predictor", {})
    model = predictor.get("model", {}) if isinstance(predictor, dict) else {}
    if isinstance(model, dict) and model.get("runtime") == LEGACY_RUNTIME_NAME:
        model["runtime"] = CANONICAL_RUNTIME_NAME

    model_format = model.get("modelFormat", {}) if isinstance(model, dict) else {}
    format_name = (
        str(model_format.get("name", "")).strip().lower()
        if isinstance(model_format, dict)
        else ""
    )
    runtime_name = str(model.get("runtime", "")).strip() if isinstance(model, dict) else ""
    if runtime_name == CANONICAL_RUNTIME_NAME:
        model_class_value = str(labels.get("modelClass", "")).strip()
        if not model_class_value:
            raise ValueError(
                "runtime kserve-mlserver-custom requires metadata.labels.modelClass "
                f"for modelFormat.name={format_name!r}"
            )

    storage_uri = model.get("storageUri") if isinstance(model, dict) else None
    if isinstance(storage_uri, str) and storage_uri.startswith("s3://") and storage_secret_name:
        annotations.setdefault(S3_STORAGE_SECRET_ANNOTATION, storage_secret_name)
        if isinstance(predictor, dict):
            predictor.setdefault("serviceAccountName", S3_STORAGE_SERVICE_ACCOUNT)

    return rendered


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render KServe InferenceService manifest")
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--registered-model", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--resolved-version", default="")
    parser.add_argument("--intent-hash", default="")
    parser.add_argument("--trace-id", required=True)
    parser.add_argument("--intent-json-b64", required=True)
    parser.add_argument("--storage-secret-name", default="mlflow-s3-credentials")
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    result = {
        "render_status": "failed",
        "reason": "invalid_json",
        "manifest_b64": "",
        "metadata_name": "",
    }

    try:
        intent = _decode_intent(args.intent_json_b64)
        _validate_intent(intent)

        rendered = _render_manifest(
            intent=intent,
            tenant=args.tenant,
            namespace=args.namespace,
            registered_model=args.registered_model,
            alias=args.alias,
            resolved_version=args.resolved_version,
            intent_hash=args.intent_hash,
            storage_secret_name=args.storage_secret_name,
        )

        manifest_json = json.dumps(rendered, sort_keys=True, indent=2)
        result["manifest_b64"] = base64.b64encode(manifest_json.encode("utf-8")).decode("utf-8")
        result["metadata_name"] = str(rendered.get("metadata", {}).get("name", ""))
        result["render_status"] = "accepted"
        result["reason"] = "rendered"
        print(
            json.dumps(
                {
                    "event": "render_manifest",
                    "status": "accepted",
                    "tenant": args.tenant,
                    "registered_model": args.registered_model,
                    "alias": args.alias,
                    "resolved_version": args.resolved_version,
                    "metadata_name": result["metadata_name"],
                },
                sort_keys=True,
            ),
            file=sys.stderr,
            flush=True,
        )

    except Exception as exc:
        result["render_status"] = "failed"
        result["reason"] = "invalid_json"
        print(
            json.dumps(
                {
                    "event": "render_manifest",
                    "status": "failed",
                    "tenant": args.tenant,
                    "registered_model": args.registered_model,
                    "alias": args.alias,
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                },
                sort_keys=True,
            ),
            file=sys.stderr,
            flush=True,
        )
        traceback.print_exc(file=sys.stderr)

    for key, value in result.items():
        _write_output(output_dir / key, value)

    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
