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
kubernetesVersion: "${k8s_version}.0"
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

%{ if install_argocd ~}
# ── AWS Cloud Controller Manager ──────────────────────────────────────────
echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo update
helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
  --namespace kube-system \
  --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=false}'

# ── CNI Implementation ───────────────────────────────────────────────────
echo "=== Installing CNI ===" >> /var/log/kubeadm-init.log
kubectl apply -f ${cni_manifest_url}
  
echo "=== Waiting for node to become Ready ===" >> /var/log/kubeadm-init.log
kubectl wait node --all --for=condition=Ready --timeout=300s

# ── Argo CD Setup (Hub Only) ──────────────────────────────────────────────
echo "=== Installing Argo CD ===" >> /var/log/kubeadm-init.log
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace ${argocd_namespace} \
  --create-namespace \
  %{ if argocd_chart_version != "" ~}
  --version "${argocd_chart_version}" \
  %{ endif ~}
  --set configs.params."server\.insecure"=true
%{ endif ~}

%{ if install_eso ~}
# ── External Secrets Operator Setup (Hub Only) ────────────────────────────
echo "=== Installing External Secrets Operator ===" >> /var/log/kubeadm-init.log
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace

ESO_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "${env}/eso/bootstrap-credentials" \
  --region "$AWS_REGION" --query SecretString --output text)
ESO_ACCESS_KEY=$(echo "$ESO_CREDS" | jq -r .access_key_id)
ESO_SECRET_KEY=$(echo "$ESO_CREDS" | jq -r .secret_access_key)

kubectl create secret generic aws-creds -n external-secrets \
  --from-literal=access-key-id="$ESO_ACCESS_KEY" \
  --from-literal=secret-access-key="$ESO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: argocd-clusters-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: "$AWS_REGION"
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: aws-creds
            namespace: external-secrets
            key: access-key-id
          secretAccessKeySecretRef:
            name: aws-creds
            namespace: external-secrets
            key: secret-access-key
EOF
%{ endif ~}

%{ if register_with_hub ~}
# ── Hub Cluster Token Registration (Spokes Only) ──────────────────────────
echo "=== Creating argocd-manager service account ===" >> /var/log/kubeadm-init.log
kubectl create namespace argocd-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount argocd-manager -n argocd-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding argocd-manager-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd-manager:argocd-manager \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<'ROTATE' > /usr/local/bin/push-argocd-registration.sh
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
MASTER_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

TOKEN=$(kubectl create token argocd-manager -n argocd-manager --duration=2160h)
CA_DATA=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SECRET_NAME="argocd-clusters/${cluster_name}"
SERVER_URL="https://$MASTER_IP:6443"

PAYLOAD=$(jq -n \
  --arg name "${cluster_name}" \
  --arg server "$SERVER_URL" \
  --arg token "$TOKEN" \
  --arg ca "$CA_DATA" \
  '{name:$name, server:$server, token:$token, caData:$ca}')

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" \
  --secret-string "$PAYLOAD" \
  --region "$AWS_REGION" 2>/dev/null || \
aws secretsmanager create-secret \
  --name "$SECRET_NAME" \
  --secret-string "$PAYLOAD" \
  --tags Key=ManagedBy,Value=k8s-bootstrap Key=ClusterName,Value=${cluster_name} Key=Purpose,Value=argocd-registration \
  --region "$AWS_REGION"
ROTATE
chmod +x /usr/local/bin/push-argocd-registration.sh
/usr/local/bin/push-argocd-registration.sh

cat <<'TIMERUNIT' > /etc/systemd/system/argocd-registration-rotate.timer
[Unit]
Description=Rotate argocd-manager token every 30 days
[Timer]
OnCalendar=*-*-1..28/30 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
TIMERUNIT
cat <<'SERVICEUNIT' > /etc/systemd/system/argocd-registration-rotate.service
[Unit]
Description=Push refreshed argocd-manager token to Secrets Manager
[Service]
Type=oneshot
ExecStart=/usr/local/bin/push-argocd-registration.sh
SERVICEUNIT
systemctl daemon-reload
systemctl enable --now argocd-registration-rotate.timer
%{ endif ~}

# ── Generate Structured Join Manifest and Push to SSM ───────────────────
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