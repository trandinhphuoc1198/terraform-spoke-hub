#!/bin/bash
# Scales ArgoCD's own controllers on THIS cluster to 0 before this same
# job's drain-pvcs.sh / drain-loadbalancers.sh steps run.
#
# Only meaningful for a cluster that runs ArgoCD locally (the hub).
# Spokes don't need this — they're already protected by
# k8s-deregister-from-hub.yml, which deletes their Applications remotely
# on the hub before drain-cluster.yml even starts.
#
# Handles both Deployment- and StatefulSet-shaped application-controller
# (chart-version dependent) without needing to know which is in use.
#
# Best-effort, matches the rest of this drain job: a failure here logs a
# warning upstream rather than blocking teardown.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

ARGOCD_NAMESPACE="__ARGOCD_NAMESPACE__"

echo "=== Freezing ArgoCD controllers in namespace ${ARGOCD_NAMESPACE} ==="

FROZE_ANY=false

if kubectl get deployment argocd-applicationset-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling deployment/argocd-applicationset-controller to 0 (stops regenerating Applications)..."
  kubectl scale deployment argocd-applicationset-controller -n "$ARGOCD_NAMESPACE" --replicas=0
  FROZE_ANY=true
fi

if kubectl get deployment argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling deployment/argocd-application-controller to 0 (stops selfHeal reconciliation)..."
  kubectl scale deployment argocd-application-controller -n "$ARGOCD_NAMESPACE" --replicas=0
  FROZE_ANY=true
elif kubectl get statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling statefulset/argocd-application-controller to 0 (stops selfHeal reconciliation)..."
  kubectl scale statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" --replicas=0
  FROZE_ANY=true
fi

if [ "$FROZE_ANY" = false ]; then
  echo "WARNING: no argocd-application-controller/argocd-applicationset-controller workload found in ${ARGOCD_NAMESPACE} — nothing to freeze."
  exit 0
fi

echo "=== Waiting for application-controller pod(s) to terminate (up to 90s) ==="
for i in $(seq 1 18); do
  REMAINING=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller --no-headers 2>/dev/null | wc -l)
  if [ "$REMAINING" -eq 0 ]; then
    echo "argocd-application-controller is fully scaled down — selfHeal can no longer race this drain."
    exit 0
  fi
  echo "  $REMAINING pod(s) still terminating (attempt $i/18)..."
  sleep 5
done

echo "WARNING: argocd-application-controller pod(s) still present after 90s — selfHeal may still be active. Proceeding with drain anyway (best-effort)."
exit 0