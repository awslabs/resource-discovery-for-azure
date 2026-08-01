#!/usr/bin/env bash
# Azure DevOps self-hosted agent bootstrap for a KEDA ScaledJob pod.
# Based on Microsoft's documented Linux docker-agent start script, with the KEDA
# `--once` modification so each pod registers, runs exactly ONE job, then exits
# (ScaledJob spins up one pod per queued pipeline job).
#
# Required env (from the Secret in trigger-auth.yaml):
#   AZP_URL   - https://dev.azure.com/<org>
#   AZP_TOKEN - PAT with Agent Pools (Read & manage)
#   AZP_POOL  - target self-hosted pool name (e.g. keda-pool)
set -euo pipefail

if [ -z "${AZP_URL:-}" ]; then echo 1>&2 "error: AZP_URL is required"; exit 1; fi
if [ -z "${AZP_TOKEN:-}" ]; then echo 1>&2 "error: AZP_TOKEN is required"; exit 1; fi

AZP_POOL="${AZP_POOL:-Default}"
# Use the shell built-in $HOSTNAME (k8s sets it to the pod name); the external
# `hostname` binary is not present on the minimal UBI base image.
AZP_AGENT_NAME="${AZP_AGENT_NAME:-${HOSTNAME:-rda-agent}}"
AZP_WORK="${AZP_WORK:-_work}"

cleanup() {
  if [ -e ./config.sh ]; then
    echo "Removing agent registration..."
    ./config.sh remove --unattended --auth PAT --token "$AZP_TOKEN" || true
  fi
}

# Download the agent package matching the org's current version.
echo "Determining matching Azure Pipelines agent..."
AZP_AGENT_PACKAGES=$(curl -LsS \
  -u user:"$AZP_TOKEN" \
  -H 'Accept:application/json;api-version=3.0-preview' \
  "$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64&top=1")
AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')

echo "Downloading and extracting agent..."
curl -LsS "$AZP_AGENT_PACKAGE_LATEST_URL" | tar -xz

echo "Configuring agent..."
./config.sh --unattended \
  --agent "$AZP_AGENT_NAME" \
  --url "$AZP_URL" \
  --auth PAT \
  --token "$AZP_TOKEN" \
  --pool "$AZP_POOL" \
  --work "$AZP_WORK" \
  --replace \
  --acceptTeeEula

# Placeholder mode: a self-hosted pool that has NEVER had an agent fast-fails
# every job with "No agent found ... which satisfies the specified demands"
# before KEDA can scale one up. Registering one agent and leaving it OFFLINE
# (registered but not running, and NOT de-registered) makes Azure DevOps keep
# jobs QUEUED, giving the KEDA azure-pipelines scaler time to spawn a real
# ephemeral agent. When AZP_PLACEHOLDER=true we register and exit WITHOUT setting
# the de-register cleanup trap and WITHOUT running, so the agent stays listed.
if [ "${AZP_PLACEHOLDER:-}" = "true" ]; then
  echo "Placeholder agent '$AZP_AGENT_NAME' registered (stays offline in pool); exiting without running."
  exit 0
fi

# Register cleanup so the agent de-registers on exit/termination.
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "Running agent for a single job (--once)..."
chmod +x ./run.sh
./run.sh --once & wait $!
