#!/usr/bin/env python3
"""Resolve MLflow model alias and deployment intent payload."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import socket
import time
import sys
import urllib.parse
import urllib.request
import urllib.error
import uuid
from dataclasses import dataclass
from typing import Any, Dict

from mlflow import MlflowClient
from mlflow import artifacts as mlflow_artifacts
from mlflow.exceptions import MlflowException


INTENT_MODE_TAG = "kserve.intent.mode"
INTENT_PAYLOAD_TAG = "kserve.intent.payload"
INTENT_REF_TAG = "kserve.intent.ref"
DEFAULT_NETWORK_TIMEOUT_SECONDS = 15
DEFAULT_PREFLIGHT_RETRIES = 4


@dataclass
class ResolveResult:
    sync_status: str = "failed"
    reason: str = "unknown_error"
    trace_id: str = ""
    model_version: str = ""
    run_id: str = ""
    source: str = ""
    intent_hash: str = ""
    intent_json_b64: str = ""
    intent_name: str = ""


def _write_output(path: pathlib.Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def _normalize_trace_id(value: str) -> str:
    if value.strip():
        return value.strip()
    return str(uuid.uuid4())


def _load_artifact_ref(ref: str, run_id: str) -> str:
    normalized = ref.strip()
    if normalized.startswith("artifacts:/"):
        if not run_id:
            raise ValueError("artifact ref requires model version run_id")
        rel_path = normalized.removeprefix("artifacts:/").lstrip("/")
        if not rel_path:
            raise ValueError("artifact ref path is empty")
        artifact_uri = f"runs:/{run_id}/{rel_path}"
    elif normalized.startswith(("runs:/", "models:/", "http://", "https://")):
        artifact_uri = normalized
    else:
        # Treat bare path as run-relative artifact path.
        if not run_id:
            raise ValueError("relative artifact ref requires model version run_id")
        artifact_uri = f"runs:/{run_id}/{normalized.lstrip('/')}"

    local_path = mlflow_artifacts.download_artifacts(artifact_uri=artifact_uri)
    path = pathlib.Path(local_path)
    if path.is_dir():
        json_files = sorted(path.glob("*.json"))
        if not json_files:
            raise ValueError(f"artifact ref directory has no json file: {artifact_uri}")
        path = json_files[0]

    return path.read_text(encoding="utf-8")


def _validate_intent(intent: Dict[str, Any]) -> None:
    if not isinstance(intent, dict):
        raise ValueError("intent must be a JSON object")

    metadata = intent.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError("intent.metadata must be an object")

    name = metadata.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("intent.metadata.name is required")

    spec = intent.get("spec")
    if not isinstance(spec, dict):
        raise ValueError("intent.spec must be an object")


def _canonical_json(value: Dict[str, Any]) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _configure_network_timeout(seconds: int) -> None:
    timeout = max(1, seconds)
    socket.setdefaulttimeout(timeout)
    os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", str(timeout))


def _preflight_tracking_uri(tracking_uri: str, timeout_seconds: int, retries: int) -> None:
    parsed = urllib.parse.urlparse(tracking_uri)
    if parsed.scheme not in {"http", "https"}:
        return
    base = tracking_uri.rstrip("/")
    # Reachability probe only: API surface can vary by MLflow version/config.
    url = f"{base}/"
    attempts = max(1, retries)
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout_seconds):
                return
        except urllib.error.HTTPError as exc:
            # 4xx/405 means server is reachable; auth/path differences are handled later.
            if 400 <= exc.code < 500:
                return
            last_error = exc
            if attempt < attempts:
                time.sleep(min(2 * attempt, 5))
        except Exception as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(min(2 * attempt, 5))
    if last_error:
        raise last_error


def _resolve_intent_payload(tags: Dict[str, str], run_id: str) -> str:
    mode = (tags.get(INTENT_MODE_TAG) or "").strip().lower()

    if not mode:
        if tags.get(INTENT_PAYLOAD_TAG):
            mode = "inline"
        elif tags.get(INTENT_REF_TAG):
            mode = "artifact-ref"
        else:
            raise KeyError("missing intent mode and payload/ref tags")

    if mode == "inline":
        payload = tags.get(INTENT_PAYLOAD_TAG)
        if not payload:
            raise KeyError(f"missing tag {INTENT_PAYLOAD_TAG}")
        return payload

    if mode == "artifact-ref":
        ref = tags.get(INTENT_REF_TAG)
        if not ref:
            raise KeyError(f"missing tag {INTENT_REF_TAG}")
        return _load_artifact_ref(ref, run_id)

    raise KeyError(f"unsupported intent mode: {mode}")


def resolve(
    tracking_uri: str,
    registered_model: str,
    alias: str,
    trace_id: str,
    timeout_seconds: int,
    preflight_retries: int,
) -> ResolveResult:
    result = ResolveResult(trace_id=_normalize_trace_id(trace_id))

    try:
        _configure_network_timeout(timeout_seconds)
        try:
            _preflight_tracking_uri(tracking_uri, timeout_seconds, preflight_retries)
        except Exception as exc:
            print(
                f"mlflow preflight failed uri={tracking_uri!r} error={type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            result.reason = "mlflow_unreachable"
            return result

        client = MlflowClient(tracking_uri=tracking_uri)

        try:
            model_version = client.get_model_version_by_alias(registered_model, alias)
        except MlflowException as exc:
            print(
                f"alias lookup failed model={registered_model!r} alias={alias!r} "
                f"error={type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            result.reason = "alias_lookup_failed"
            return result

        result.model_version = str(model_version.version)
        result.run_id = model_version.run_id or ""
        result.source = model_version.source or ""

        tags: Dict[str, str] = dict(model_version.tags or {})
        try:
            payload = _resolve_intent_payload(tags, result.run_id)
        except KeyError as exc:
            print(
                f"intent missing model={registered_model!r} alias={alias!r} "
                f"error={type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            result.reason = "intent_missing"
            return result
        except Exception as exc:
            print(
                f"intent read failed model={registered_model!r} alias={alias!r} "
                f"error={type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            result.reason = "intent_missing"
            return result

        try:
            intent = json.loads(payload)
            _validate_intent(intent)
        except Exception as exc:
            print(
                f"intent parse failed model={registered_model!r} alias={alias!r} "
                f"error={type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            result.reason = "invalid_json"
            return result

        canonical = _canonical_json(intent)
        result.intent_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        result.intent_json_b64 = base64.b64encode(canonical.encode("utf-8")).decode("utf-8")
        result.intent_name = str(intent.get("metadata", {}).get("name", ""))
        result.sync_status = "accepted"
        result.reason = "accepted"
        return result

    except Exception as exc:
        print(
            f"resolve failed model={registered_model!r} alias={alias!r} "
            f"error={type(exc).__name__}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        result.reason = "unknown_error"
        return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve MLflow alias and deployment intent")
    parser.add_argument("--registered-model", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--trace-id", default="")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--tracking-uri",
        default=os.getenv("MLFLOW_TRACKING_URI", ""),
        help="MLflow tracking URI (defaults to MLFLOW_TRACKING_URI env var)",
    )
    parser.add_argument(
        "--network-timeout-seconds",
        type=int,
        default=int(os.getenv("MLFLOW_SYNC_NETWORK_TIMEOUT_SECONDS", str(DEFAULT_NETWORK_TIMEOUT_SECONDS))),
        help="Timeout for MLflow and artifact network calls",
    )
    parser.add_argument(
        "--preflight-retries",
        type=int,
        default=int(os.getenv("MLFLOW_SYNC_PREFLIGHT_RETRIES", str(DEFAULT_PREFLIGHT_RETRIES))),
        help="Number of MLflow preflight attempts before failing",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    result = ResolveResult(trace_id=_normalize_trace_id(args.trace_id))
    print(
        json.dumps(
            {
                "event": "resolve_start",
                "registered_model": args.registered_model,
                "alias": args.alias,
                "tracking_uri": args.tracking_uri,
                "trace_id": result.trace_id,
            },
            sort_keys=True,
        ),
        file=sys.stderr,
        flush=True,
    )

    if not args.tracking_uri:
        result.reason = "alias_lookup_failed"
    else:
        result = resolve(
            tracking_uri=args.tracking_uri,
            registered_model=args.registered_model,
            alias=args.alias,
            trace_id=args.trace_id,
            timeout_seconds=args.network_timeout_seconds,
            preflight_retries=args.preflight_retries,
        )

    output_map = {
        "sync_status": result.sync_status,
        "reason": result.reason,
        "trace_id": result.trace_id,
        "model_version": result.model_version,
        "run_id": result.run_id,
        "source": result.source,
        "intent_hash": result.intent_hash,
        "intent_json_b64": result.intent_json_b64,
        "intent_name": result.intent_name,
    }

    for key, value in output_map.items():
        _write_output(output_dir / key, value)

    print(
        json.dumps(
            {
                "event": "resolve_result",
                "registered_model": args.registered_model,
                "alias": args.alias,
                "sync_status": result.sync_status,
                "reason": result.reason,
                "model_version": result.model_version,
                "intent_name": result.intent_name,
                "intent_hash": result.intent_hash,
                "trace_id": result.trace_id,
            },
            sort_keys=True,
        ),
        file=sys.stderr,
        flush=True,
    )
    print(json.dumps(output_map, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
