#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k8s-bootstrap.log) 2>&1

export PATH=$PATH:/usr/local/bin

# ── Retrieve Instance Metadata via IMDSv2 ───────────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# ── Create Kubeadm Cluster Configuration ─────────────────────────────────
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "${k8s_version}"
apiServer:
  extraArgs:
    cloud-provider: "external"
controllerManager:
  extraArgs:
    cloud-provider: "external"
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
etcd:
  local:
    extraArgs:
      listen-metrics-urls: "http://127.0.0.1:2381,http://$PRIVATE_IP:2381"
networking:
  podSubnet: "${pod_cidr}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
systemReserved:
  memory: "100Mi"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
skipPhases:
  - addon/kube-proxy
localAPIEndpoint:
  advertiseAddress: "$PRIVATE_IP"
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    cloud-provider: "external"
EOF

# ── Run kubeadm init ──────────────────────────────────────────────────────
kubeadm init --config=/tmp/kubeadm-config.yaml 2>&1 | tee /var/log/kubeadm-init.log

# ── kubectl setup for ec2-user ────────────────────────────────────────────
mkdir -p /home/ec2-user/.kube
cp /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
chown ec2-user:ec2-user /home/ec2-user/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# ── Wait for apiserver to be consistently reachable ───────────────────────
# kubeadm init can finish with a brief window where the apiserver is still
# cycling (e.g. kubelet restarting to pick up the rotated client cert in
# [kubelet-finalize]). Racing straight into `helm install` against it can
# hit a transient "connection refused" / GOAWAY. Wait for a stable
# response before proceeding.
echo "=== Waiting for apiserver to be consistently reachable ===" >> /var/log/kubeadm-init.log
for i in $(seq 1 30); do
  if kubectl get --raw='/readyz' >/dev/null 2>&1; then
    echo "apiserver is ready (attempt $i)" >> /var/log/kubeadm-init.log
    break
  fi
  echo "apiserver not ready yet, retrying in 5s (attempt $i/30)..." >> /var/log/kubeadm-init.log
  sleep 5
done

# ── CNI ─────────────────────────────────────────────────────────────────
# Unconditional — every cluster (hub and spoke) needs pod networking to
# reach Ready, regardless of whether it also runs Argo CD/CCM/ESO.
echo "=== Installing CNI ===" >> /var/log/kubeadm-init.log
helm repo add cilium https://helm.cilium.io/
helm repo update

for i in $(seq 1 5); do
  helm upgrade --install cilium cilium/cilium \
    --version  "1.16.0" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$PRIVATE_IP" \
    --set k8sServicePort="6443" \
    --set tunnel=disabled \
    --set ipam.mode=kubernetes \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="${pod_cidr}" \
    --set bpf.masquerade=true \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hubble.metrics.enabled="{dns:query;ignoreAAAA,drop,tcp,flow,icmp,http}" \
    --wait \
    --timeout 5m && break
  echo "Cilium install attempt $i failed, retrying in 10s..." >> /var/log/kubeadm-init.log
  sleep 10
done

echo "=== Waiting for node to become Ready ===" >> /var/log/kubeadm-init.log
kubectl wait node --all --for=condition=Ready --timeout=300s

# ── AWS Cloud Controller Manager ──────────────────────────────────────────
# Unconditional — every node registers with cloud-provider=external, so every
# node (hub and spoke, master and workers) carries the
# node.cloudprovider.kubernetes.io/uninitialized:NoSchedule taint until CCM
# runs and clears it. This MUST happen before anything else tries to
# schedule — including Argo CD's own pods, which is why this can't be an
# Argo CD Application (Argo CD's chart ships no toleration for this taint;
# CNI's DaemonSet does, which is why CNI is safe to apply before this step).
echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo update
helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
  --namespace kube-system \
  --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=false}'

echo "=== Waiting for uninitialized taint to clear ===" >> /var/log/kubeadm-init.log
timeout 120 bash -c 'until ! kubectl get nodes -o json | grep -q "node.cloudprovider.kubernetes.io/uninitialized"; do sleep 5; done'

# ── Generate Structured Join Manifest and Push to SSM ───────────────────
# This is the only "hand-off" Terraform-owned bootstrap needs to make:
# it publishes what a worker needs to join. Everything past "node is
# Ready" (CCM, Argo CD, ESO, hub registration) is intentionally NOT here
# anymore — see modules/k8s/README.md for where each of those now lives.
echo "=== Pushing JSON Join Payload to SSM ===" >> /var/log/kubeadm-init.log
TOKEN=$(kubeadm token create --ttl 24h)
CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')
API_ENDPOINT="$PRIVATE_IP:6443"

JOIN_PAYLOAD=$(jq -n \
  --arg tok "$TOKEN" \
  --arg hash "sha256:$CA_HASH" \
  --arg ep "$API_ENDPOINT" \
  '{token: $tok, ca_hash: $hash, endpoint: $ep}')

aws ssm put-parameter \
  --name "/${env}/k8s/join_token" \
  --value "$JOIN_PAYLOAD" \
  --type "SecureString" \
  --overwrite \
  --region "$AWS_REGION"

echo 'alias k=kubectl' >> /home/ec2-user/.bashrc