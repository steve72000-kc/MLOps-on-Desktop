#!/usr/bin/env python3
"""Write GitOps synchronization status tags to an MLflow model version."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import socket
import sys
import time

from mlflow import MlflowClient

DEFAULT_NETWORK_TIMEOUT_SECONDS = 15
DEFAULT_TAG_WRITE_RETRIES = 3
STATUS_RANK = {
    "accepted": 10,
    "rendered": 20,
    "applied": 30,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update MLflow status tags for model version")
    parser.add_argument("--registered-model", required=True)
    parser.add_argument("--model-version", default="")
    parser.add_argument("--sync-status", required=True)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--trace-id", required=True)
    parser.add_argument("--commit-sha", default="")
    parser.add_argument("--deployment-url", default="")
    parser.add_argument(
        "--tracking-uri",
        default=os.getenv("MLFLOW_TRACKING_URI", ""),
        help="MLflow tracking URI (defaults to MLFLOW_TRACKING_URI env var)",
    )
    parser.add_argument(
        "--network-timeout-seconds",
        type=int,
        default=int(os.getenv("MLFLOW_SYNC_NETWORK_TIMEOUT_SECONDS", str(DEFAULT_NETWORK_TIMEOUT_SECONDS))),
        help="Timeout for MLflow network calls",
    )
    parser.add_argument(
        "--tag-write-retries",
        type=int,
        default=int(os.getenv("MLFLOW_SYNC_TAG_WRITE_RETRIES", str(DEFAULT_TAG_WRITE_RETRIES))),
        help="Retries per model version tag write",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    timeout = max(1, args.network_timeout_seconds)
    retries = max(1, args.tag_write_retries)
    socket.setdefaulttimeout(timeout)
    os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", str(timeout))

    if not args.tracking_uri:
        print("Skipping status update: MLFLOW_TRACKING_URI is not set")
        return 0

    if not args.model_version:
        print("Skipping status update: model version is empty")
        return 0

    client = MlflowClient(tracking_uri=args.tracking_uri)

    current_status = None
    try:
        mv = client.get_model_version(name=args.registered_model, version=args.model_version)
        current_status = (mv.tags or {}).get("gitops.sync.status")
    except Exception:
        # Best effort read; do not block status write if this lookup fails.
        current_status = None

    # Enforce monotonic progression for non-failure statuses.
    # `failed` is always allowed so teams get immediate failure feedback.
    if args.sync_status != "failed":
        curr_rank = STATUS_RANK.get(current_status or "")
        next_rank = STATUS_RANK.get(args.sync_status)
        if curr_rank is not None and next_rank is not None and next_rank < curr_rank:
            print(
                "Skipping status downgrade",
                {
                    "registered_model": args.registered_model,
                    "model_version": args.model_version,
                    "current_status": current_status,
                    "requested_status": args.sync_status,
                },
            )
            return 0

    tags = {
        "gitops.sync.status": args.sync_status,
        "gitops.sync.reason": args.reason,
        "gitops.sync.trace_id": args.trace_id,
        "gitops.sync.updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }

    if args.commit_sha:
        tags["gitops.sync.commit"] = args.commit_sha
    if args.deployment_url:
        tags["gitops.sync.url"] = args.deployment_url

    for key, value in tags.items():
        last_error: Exception | None = None
        for attempt in range(1, retries + 1):
            try:
                client.set_model_version_tag(
                    name=args.registered_model,
                    version=args.model_version,
                    key=key,
                    value=value,
                )
                last_error = None
                break
            except Exception as exc:
                last_error = exc
                print(
                    f"status tag write failed attempt={attempt}/{retries} key={key!r} "
                    f"error={type(exc).__name__}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                if attempt < retries:
                    time.sleep(min(2 * attempt, 5))

        if last_error is not None:
            raise last_error

    print(
        "Updated MLflow tags",
        {
            "registered_model": args.registered_model,
            "model_version": args.model_version,
            "status": args.sync_status,
            "reason": args.reason,
            "trace_id": args.trace_id,
            "commit": args.commit_sha,
            "deployment_url": args.deployment_url,
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
