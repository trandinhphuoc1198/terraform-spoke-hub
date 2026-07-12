#!/bin/bash
set -euo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

ARGOCD_NAMESPACE="__ARGOCD_NAMESPACE__"
ARGOCD_CHART_VERSION="__ARGOCD_CHART_VERSION__"
GITOPS_REPO_RAW_URL="__GITOPS_REPO_RAW_URL__"

echo "=== Installing Argo CD ==="
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

if [ -n "$ARGOCD_CHART_VERSION" ]; then
  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --set configs.params."server\.insecure"=true
else
  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" --create-namespace \
    --set configs.params."server\.insecure"=true
fi

echo "=== Waiting for Argo CD CRDs ==="
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
kubectl wait --for=condition=Established crd/appprojects.argoproj.io --timeout=180s
kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=180s

# This is the ONLY kubectl apply of gitops-repo content that comes from CI.
# Everything downstream — CCM, ESO, all apps — is Argo CD syncing from Git
# continuously from this point forward.
echo "=== Applying Argo CD bootstrap manifests from gitops repo ==="
kubectl apply -f "$GITOPS_REPO_RAW_URL/argocd/projects/platform-infra.yaml"
kubectl apply -f "$GITOPS_REPO_RAW_URL/argocd/projects/platform-apps.yaml"
kubectl apply -f "$GITOPS_REPO_RAW_URL/argocd/root-app.yaml"