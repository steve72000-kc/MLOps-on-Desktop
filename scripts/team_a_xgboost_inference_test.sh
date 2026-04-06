#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"
MODEL_HOST="${MODEL_HOST:-xgboost-synth-v1-predictor.ml-team-a.ai-ml.local}"
BASE_URL="${BASE_URL:-}"
DEFAULT_PAYLOAD='{"inputs":[{"name":"predict","shape":[1,4],"datatype":"FP32","data":[[6.8,2.8,4.8,1.4]]}]}'
PAYLOAD="${PAYLOAD:-$DEFAULT_PAYLOAD}"
SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
Usage:
  ./scripts/${SCRIPT_NAME}
  BASE_URL=http://172.29.0.203 ./scripts/${SCRIPT_NAME}
  BASE_URL=http://localhost:8080 ./scripts/${SCRIPT_NAME}

Env vars:
  MODEL_NAME   Model name in the infer path
  MODEL_HOST   Predictor host to call directly or send as Host header
  BASE_URL     Optional ingress URL such as http://localhost:8080 or http://172.29.0.203
  PAYLOAD      Optional raw JSON payload

When BASE_URL is empty, the script calls http://\${MODEL_HOST} directly, so
\${MODEL_HOST} must resolve locally (for example through /etc/hosts).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
    echo "Invalid PAYLOAD JSON. Fix PAYLOAD before retrying." >&2
    exit 1
  fi
fi

if [ -n "$BASE_URL" ]; then
  REQUEST_URL="${BASE_URL%/}/v2/models/${MODEL_NAME}/infer"
  RESPONSE="$(curl -sS "$REQUEST_URL" \
    -H "Host: ${MODEL_HOST}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"
else
  REQUEST_URL="http://${MODEL_HOST}/v2/models/${MODEL_NAME}/infer"
  RESPONSE="$(curl -sS "$REQUEST_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"
fi

printf 'model_name: %s\n' "$MODEL_NAME"
printf 'model_host: %s\n' "$MODEL_HOST"
printf 'request_url: %s\n' "$REQUEST_URL"
printf 'response:\n'

if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$RESPONSE" | jq .
else
  printf '%s\n' "$RESPONSE"
fi
