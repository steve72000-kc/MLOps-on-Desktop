#!/usr/bin/env bash
set -eu

# Core CLI dependencies required by the bootstrap flow.
requirements=(
  docker
  kind
  kubectl
  helm
  git
  curl
  ssh
  ssh-keygen
)

# Track tools missing from PATH and report them together.
missing=()

for cmd in "${requirements[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required dependencies:"
  for cmd in "${missing[@]}"; do
    echo "- $cmd"
  done
  echo
  echo "Install missing dependencies and retry."
  exit 1
fi

# Validate Docker daemon connectivity before bootstrap starts.
if ! docker_info_out="$(docker info 2>&1)"; then
  echo "Docker CLI is installed, but daemon connectivity failed."
  echo
  echo "$docker_info_out"
  echo
  # Context hint to reduce debugging time when rootless/default are misconfigured.
  if docker_context_name="$(docker context show 2>/dev/null)"; then
    echo "Current docker context: $docker_context_name"
    if [ "$docker_context_name" = "rootless" ]; then
      echo "The 'rootless' context expects a user daemon socket (for example /run/user/\$UID/docker.sock)."
      echo "If you want the system daemon, switch context: docker context use default"
      echo "If you want rootless, start the user daemon first."
    fi
  fi
  exit 1
fi

echo "Prereqs OK."
