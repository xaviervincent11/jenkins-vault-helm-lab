#!/usr/bin/env sh
set -u

NAMESPACE="${NAMESPACE:-jenkins}"
SERVICE="${SERVICE:-jenkins}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
REMOTE_PORT="${REMOTE_PORT:-8080}"
RETRY_SECONDS="${RETRY_SECONDS:-3}"

echo "Forwarding http://127.0.0.1:${LOCAL_PORT} to svc/${SERVICE}:${REMOTE_PORT} in namespace ${NAMESPACE}."
echo "Press Ctrl+C to stop."

while true; do
  kubectl -n "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}"
  status=$?
  echo "kubectl port-forward exited with status ${status}. Restarting in ${RETRY_SECONDS}s..."
  sleep "$RETRY_SECONDS"
done
