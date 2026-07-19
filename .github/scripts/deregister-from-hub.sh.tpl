#!/bin/bash
# Fully deregisters one spoke cluster from ArgoCD, run ON THE HUB MASTER.
#
# Exits non-zero on any step that can't be confirmed — this script is
# intentionally NOT tolerant of failure. The whole point of running it
# before destroy-spoke's PVC drain is to guarantee no ArgoCD controller can
# recreate anything on the spoke while that drain is in progress. A partial
# failure here means that guarantee doesn't hold, so the caller should stop
# rather than proceed.
#
# Order matters and is deliberate:
#   1. Delete the ExternalSecret (+ its generated Secret) FIRST. The
#      ExternalSecret reconciles on its own refreshInterval (5m) via ESO,
#      completely independent of ArgoCD's selfHeal setting — deleting only
#      the generated Secret without this would let ESO resurrect the
#      cluster registration within minutes, undoing everything below.
#   2. Only once the cluster is gone from ArgoCD's inventory do we delete
#      the generated Applications — otherwise every spokes/ ApplicationSet
#      (selfHeal: true) can regenerate an Application faster than this
#      script deletes the previous one.
#   3. Applications are deleted in REVERSE sync-wave order, discovered
#      dynamically from each Application's own
#      argocd.argoproj.io/sync-wave annotation (every spokes/ ApplicationSet
#      template stamps this on generated Applications already) — so this
#      script needs no manual, hand-maintained list of release names.
#      Adding/removing an ApplicationSet under argocd/spokes/ never requires
#      touching this script.
#   4. CNI (cilium-*) / CSI (aws-ebs-csi-driver-*) / other node-critical
#      infra is excluded from this script's deletion entirely —
#      drain-pvcs.sh (run after this script) needs a live CSI controller and
#      live pod networking on the spoke to issue real EBS DeleteVolume calls
#      and let pods unmount cleanly. Delete those separately, later.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

CLUSTER_NAME="__CLUSTER_NAME__"

# release-name prefixes this script will NOT touch — node-critical infra
# that must stay alive on the spoke until drain-pvcs.sh has run. Add more
# here (e.g. "aws-cloud-controller-manager") if you want them held back too.
EXCLUDED_RELEASES=(
  "cilium"
  "aws-ebs-csi-driver"
)

echo "=== Deregistering cluster: $CLUSTER_NAME ==="

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

# ── Step 1: delete the ExternalSecret (and its generated Secret) ───────────
# This is what actually stops re-registration. Deleting only the generated
# Secret is not enough — ESO's refreshInterval would just recreate it.
echo "--- Deleting ExternalSecret + generated Secret ---"
EXTSECRET_NAME=$(kubectl get externalsecret -n argocd -o json 2>/dev/null \
  | jq -r --arg cn "$CLUSTER_NAME" '.items[] | select(.spec.dataFrom[]?.extract.key // "" | test($cn)) | .metadata.name' \
  | head -n1)

# Fallback: naming convention — every ExternalSecret in argocd/clusters/ is
# named after the cluster today.
if [ -z "$EXTSECRET_NAME" ]; then
  EXTSECRET_NAME=$(kubectl get externalsecret -n argocd -o name 2>/dev/null | grep -- "/${CLUSTER_NAME}$" | sed 's#.*/##' || true)
fi

if [ -z "$EXTSECRET_NAME" ]; then
  echo "No ExternalSecret found matching cluster ${CLUSTER_NAME}. Skipping (may already be deleted)."
else
  echo "Deleting ExternalSecret/${EXTSECRET_NAME}..."
  kubectl delete externalsecret -n argocd "$EXTSECRET_NAME" --wait=true --timeout=60s || {
    echo "ERROR: failed to delete ExternalSecret/${EXTSECRET_NAME}." >&2
    exit 1
  }
fi

kubectl delete secret -n argocd -l "cluster-name=${CLUSTER_NAME}" --ignore-not-found=true --wait=true --timeout=60s

echo "--- Verifying the cluster is gone from ArgoCD's inventory ---"
STILL_THERE=$(kubectl get secret -n argocd -l "cluster-name=${CLUSTER_NAME}" --no-headers 2>/dev/null | wc -l)
if [ "$STILL_THERE" -ne 0 ]; then
  echo "ERROR: cluster registration Secret still present after delete." >&2
  exit 1
fi
echo "Confirmed: cluster no longer in ArgoCD's inventory. No generator can recreate Applications for it now."

# ── Step 2: delete every Application ArgoCD generated for this spoke ───────
# Discovered dynamically and sorted by descending sync-wave (highest wave —
# e.g. fastapi-app at 50 — deleted first; lowest — e.g. cilium at 00 —
# deleted last / excluded), so no hardcoded release list to maintain.
is_excluded() {
  local release="$1"
  for ex in "${EXCLUDED_RELEASES[@]}"; do
    [ "$release" = "$ex" ] && return 0
  done
  return 1
}

echo "--- Discovering Applications targeting this cluster (sorted by descending sync-wave) ---"
APP_LIST=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r --arg cn "$CLUSTER_NAME" '
  [ .items[]
    | select(.metadata.name | endswith("-" + $cn))
    | { name: .metadata.name,
        wave: ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-1") | tonumber) }
  ]
  | sort_by(-.wave)
  | .[].name
')

if [ -z "$APP_LIST" ]; then
  echo "No Applications found for cluster ${CLUSTER_NAME}."
else
  echo "Deletion order:"
  echo "$APP_LIST"
  echo

  for app in $APP_LIST; do
    release="${app%-${CLUSTER_NAME}}"

    if is_excluded "$release"; then
      echo "Skipping ${app} (excluded — node-critical infra, delete after drain-pvcs.sh)"
      continue
    fi

    echo "Deleting application.argoproj.io/${app} (cascade=foreground — this can take a few minutes)..."
    kubectl delete application "$app" -n argocd --cascade=foreground --wait=true --timeout=600s || {
      echo "ERROR: failed to fully delete ${app} within timeout." >&2
      exit 1
    }
  done
fi

echo "--- Verifying no non-excluded Applications remain for this cluster ---"
REMAINING=$(kubectl get applications -n argocd -o name 2>/dev/null | grep -- "-${CLUSTER_NAME}$" || true)
UNEXPECTED=""
for app_path in $REMAINING; do
  app_name=$(echo "$app_path" | sed 's#.*/##')
  release="${app_name%-${CLUSTER_NAME}}"
  if ! is_excluded "$release"; then
    UNEXPECTED="${UNEXPECTED}${app_name}\n"
  fi
done

if [ -n "$UNEXPECTED" ]; then
  echo "ERROR: unexpected Applications still present after delete:" >&2
  echo -e "$UNEXPECTED" >&2
  exit 1
fi

echo "=== Deregistration complete: $CLUSTER_NAME is no longer tracked by ArgoCD ==="
echo "Excluded and left running on purpose (delete these AFTER drain-pvcs.sh):"
for release in "${EXCLUDED_RELEASES[@]}"; do
  app="${release}-${CLUSTER_NAME}"
  kubectl get application "$app" -n argocd >/dev/null 2>&1 && echo "  - $app"
done
echo
echo "Note: any PersistentVolumeClaim created via a StatefulSet volumeClaimTemplate"
echo "(Prometheus, Tempo ingester) is NOT deleted by this step — Kubernetes"
echo "deliberately leaves those unowned so they survive pod recreation. They are"
echo "simply idle now (no pod holds them). The drain-pvcs.sh step that runs next"
echo "is what actually deletes them and triggers the EBS DeleteVolume calls."
echo "Run drain-pvcs.sh now, THEN manually delete: ${EXCLUDED_RELEASES[*]/%/-$CLUSTER_NAME}"