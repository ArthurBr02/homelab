#!/usr/bin/env bash
#
# Bootstrap / disaster recovery for the k3s cluster.
#
# This is the ONLY manual step after a full cluster rebuild. Everything else
# (apps, secrets) is pulled from Git by Argo CD and decrypted by the Sealed
# Secrets controller once this script has run.
#
# Prerequisites:
#   - kubectl points to the freshly rebuilt cluster
#   - the Sealed Secrets private key backup is available locally
#     (see SEALED_SECRETS_KEY_BACKUP below)
#
# Usage:
#   SEALED_SECRETS_KEY_BACKUP=/path/to/sealed-secrets-key-backup.yaml ./kubernetes/bootstrap.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
SEALED_SECRETS_INSTALL_URL="https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml"
SEALED_SECRETS_KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-}"

echo "==> 1/4 Installing Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "${ARGOCD_INSTALL_URL}"

echo "==> 2/4 Installing Sealed Secrets controller"
kubectl apply -f "${SEALED_SECRETS_INSTALL_URL}"

echo "==> 3/4 Restoring Sealed Secrets decryption key"
if [[ -z "${SEALED_SECRETS_KEY_BACKUP}" ]]; then
  echo "!! SEALED_SECRETS_KEY_BACKUP is not set."
  echo "!! Without the original key, every SealedSecret in Git becomes undecryptable"
  echo "!! and all secrets must be re-sealed by hand. Set it and re-run."
  exit 1
fi
if [[ ! -f "${SEALED_SECRETS_KEY_BACKUP}" ]]; then
  echo "!! Key backup file not found: ${SEALED_SECRETS_KEY_BACKUP}"
  exit 1
fi
kubectl apply -f "${SEALED_SECRETS_KEY_BACKUP}"
# Restart the controller so it picks up the restored key.
kubectl delete pod -n kube-system -l name=sealed-secrets-controller

echo "==> 4/4 Pointing Argo CD at the Git repository (app of apps)"
kubectl apply -f "${REPO_ROOT}/kubernetes/argocd/root-app.yaml"

echo
echo "Bootstrap done. Argo CD now reconciles everything from Git."
echo "Watch it converge with:"
echo "  kubectl get applications -n argocd -w"
