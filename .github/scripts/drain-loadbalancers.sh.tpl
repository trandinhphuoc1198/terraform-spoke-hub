#!/bin/bash
# Deletes every Kubernetes Service of type=LoadBalancer so AWS Cloud
# Controller Manager (CCM) issues the matching ELBv2 DeleteLoadBalancer
# call for the NLB/ALB it provisioned — BEFORE terraform destroy removes
# the nodes CCM needs to be running on to do that cleanup.
#
# WHY THIS IS NEEDED:
#   Every load balancer CCM creates for a LoadBalancer-type Service is not
#   a Terraform-managed resource — Terraform never sees its ARN, so
#   `terraform destroy` has no way to remove it. CCM is the only thing
#   that can delete it, and CCM can only react to `kubectl delete svc`
#   while its own pod (on the master) and the target nodes are still
#   alive. Destroy nodes first and the load balancer is orphaned in AWS:
#   it keeps billing and can block VPC/subnet deletion later.
#
# Deleting the Service (not the namespace, unlike drain-pvcs.sh) is
# enough — CCM's finalizer on the Service is what drives ELBv2 teardown.
#
# Waits for the matching load balancer to actually disappear on the AWS
# side (filtered by the kubernetes.io/cluster/<cluster_name>=owned tag
# CCM stamps on everything it creates — same tag convention already used
# on ASG/instance/route-table resources elsewhere in this repo), not just
# for `kubectl get svc` to return nothing — the Service can vanish from
# the API before CCM's DeleteLoadBalancer call actually completes.
#
# Always exits 0 — a stuck load balancer should not block terraform
# destroy from proceeding. The caller (GitHub Actions step) surfaces the
# warning so it can be cleaned up manually if needed.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

CLUSTER_NAME="__CLUSTER_NAME__"

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 0; }

echo "=== Discovering type=LoadBalancer Services ==="
LB_SVCS=$(kubectl get svc --all-namespaces -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"')

if [ -n "$LB_SVCS" ]; then
  echo "LoadBalancer Services: $(echo "$LB_SVCS" | tr '\n' ' ')"
  for svc in $LB_SVCS; do
    ns="${svc%%/*}"; name="${svc##*/}"
    echo "Deleting svc/$name -n $ns (triggers CCM's ELBv2 DeleteLoadBalancer)..."
    kubectl delete svc "$name" -n "$ns" --wait=false || true
  done
else
  echo "No LoadBalancer Services found in-cluster — checking AWS directly in case one was already deleted (e.g. via a namespace cascade) and may still be mid-teardown."
fi

# ALWAYS run — a Service can vanish from the API before CCM's
# DeleteLoadBalancer call actually completes, regardless of how it was deleted.
echo "=== Waiting for CCM to remove any load balancer tagged for this cluster (up to 6 minutes) ==="
for i in $(seq 1 36); do
  STILL_OURS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json 2>/dev/null \
    | jq -r '.LoadBalancers[].LoadBalancerArn' \
    | while read -r arn; do
        aws elbv2 describe-tags --region "$AWS_REGION" --resource-arns "$arn" --output json 2>/dev/null \
          | jq -e --arg cn "$CLUSTER_NAME" \
            '.TagDescriptions[0].Tags[]? | select(.Key=="kubernetes.io/cluster/\($cn)" and .Value=="owned")' >/dev/null \
          && echo "$arn"
      done)

  if [ -z "$STILL_OURS" ]; then
    echo "All CCM-provisioned load balancers for this cluster are gone."
    exit 0
  fi
  echo "  Still present (attempt $i/36): $STILL_OURS"
  sleep 10
done

echo "WARNING: some load balancers tagged for this cluster are still present after 6 minutes:"
echo "$STILL_OURS"
echo "Check the AWS Console/CLI (ELBv2) and delete manually if needed — terraform destroy will not remove them."
exit 0