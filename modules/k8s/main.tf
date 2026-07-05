# Renders kubeadm bootstrap scripts passed into EC2 user_data.
#
# containerd, kubeadm, kubelet, kubectl, swap-disable, kernel modules, and
# sysctl prep are now baked into the AMI at build time by Packer + Ansible
# (see /packer at the repo root and modules/ami). This module's user_data
# only handles what must happen at instance-launch time: kubeadm init/join,
# CNI, AWS CCM, and — hub only — Argo CD, none of which can be baked ahead
# of time since they depend on per-instance identity or coordination
# between the master and workers.
#
# Only the hub master additionally installs Argo CD itself (install_argocd
# = true). Spokes never install Argo CD — they are only ever *managed by*
# the hub's Argo CD instance, registered as a remote cluster after both
# clusters exist (see root README for that day-2 step).
#
# Actual application manifests / Argo CD Application/AppProject resources
# deliberately live in a separate GitOps repo, not here — this module's job
# ends at "cluster is alive and GitOps-ready".

locals {
  common = <<-COMMON
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/k8s-bootstrap.log) 2>&1
  COMMON

  master_init = <<-MASTER
    # ── install git and helm ──────────────────────────────────────────────────
    yum install -y git
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    export PATH=$PATH:/usr/local/bin

    # ── kubeadm init ──────────────────────────────────────────────────────────
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

    # ── Create Kubeadm Cluster Configuration ─────────────────────────────────
    cat <<EOF > /tmp/kubeadm-config.yaml
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: ClusterConfiguration
    kubernetesVersion: "${var.k8s_version}.0"
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
      podSubnet: "${var.pod_cidr}"
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
      with:
      advertiseAddress: "$PRIVATE_IP"
      bindPort: 6443
    nodeRegistration:
      kubeletExtraArgs:
        cloud-provider: "external"
    EOF

    # ── Run kubeadm init ──────────────────────────────────────────────────────
    kubeadm init --config=/tmp/kubeadm-config.yaml 2>&1 | tee /var/log/kubeadm-init.log

    # ── kubectl for ec2-user ──────────────────────────────────────────────────
    mkdir -p /home/ec2-user/.kube
    cp /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
    chown ec2-user:ec2-user /home/ec2-user/.kube/config
    export KUBECONFIG=/etc/kubernetes/admin.conf



    %{if var.install_argocd~}
    # ── Argo CD (hub only) ────────────────────────────────────────────────────
    # This is the ONLY application-layer thing Terraform installs, because the
    # hub cluster's entire purpose is to run it. Actual Application / AppProject
    # manifests that Argo CD then syncs live in a separate GitOps repo — not here.

    # ── AWS Cloud Controller Manager (required — removes the node's ─────────
    #    "uninitialized" taint so anything else can schedule at all) ──────────
    echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
    helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
    helm repo update
    helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
      --namespace kube-system \
      --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=false}'


    # ── CNI (required — no pod, including CCM/Argo CD, schedules without it) ──
    echo "=== Installing CNI ===" >> /var/log/kubeadm-init.log
    kubectl apply -f ${var.cni_manifest_url}
      
    echo "=== Waiting for node to become Ready ===" >> /var/log/kubeadm-init.log
    kubectl wait node --all --for=condition=Ready --timeout=300s
    
    echo "=== Installing Argo CD ===" >> /var/log/kubeadm-init.log
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    helm upgrade --install argocd argo/argo-cd \
      --namespace ${var.argocd_namespace} \
      --create-namespace \
      %{if var.argocd_chart_version != ""~}
      --version "${var.argocd_chart_version}" \
      %{endif~}
      --set configs.params."server\.insecure"=true
    %{endif~}

    %{if var.install_eso~}
    # ── External Secrets Operator (hub only) ───────────────────────────────────
    # Pulls each spoke's registration credentials out of Secrets Manager and
    # materializes them as labeled Secrets in the argocd namespace. CI applies
    # one ExternalSecret per spoke (argocd-register-spoke.yml); this refreshes
    # it forever after, so token rotation self-heals with no CI re-run needed.
    echo "=== Installing External Secrets Operator ===" >> /var/log/kubeadm-init.log
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    helm upgrade --install external-secrets external-secrets/external-secrets \
      --namespace external-secrets --create-namespace

    ESO_CREDS=$(aws secretsmanager get-secret-value \
      --secret-id "${var.env}/eso/bootstrap-credentials" \
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
    %{endif~}

    %{if var.register_with_hub~}
    # ── Register this cluster with the hub's Argo CD (spokes only) ────────────
    # cluster-admin-bound ServiceAccount, token pushed to Secrets Manager at
    # argocd-clusters/<cluster_name>. A systemd timer re-mints and re-pushes
    # every 30 days so the token never actually expires in practice.
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
    SECRET_NAME="argocd-clusters/${var.cluster_name}"
    SERVER_URL="https://$MASTER_IP:6443"

    PAYLOAD=$(jq -n \
      --arg name "${var.cluster_name}" \
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
      --tags Key=ManagedBy,Value=k8s-bootstrap Key=ClusterName,Value=${var.cluster_name} Key=Purpose,Value=argocd-registration \
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
    %{endif~}

    # ── Upload raw join command to SSM (workers parse it themselves) ──────────
    echo "=== Pushing join command to SSM ===" >> /var/log/kubeadm-init.log
    aws ssm put-parameter \
      --name "/${var.env}/k8s/join_token" \
      --value "$(kubeadm token create --print-join-command)" \
      --type "SecureString" \
      --overwrite \
      --region "$AWS_REGION"

    echo 'alias k=kubectl' >> /home/ec2-user/.bashrc
  MASTER

  worker_join = <<-WORKER
    # ── Resolve own AWS identity via IMDSv2 ──────────────────────────────────
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    AWS_REGION=$(curl -s  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s          -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    PROVIDER_ID="aws:///$${AZ}/$${INSTANCE_ID}"

    echo "Worker identity: instance=$${INSTANCE_ID} az=$${AZ} provider-id=$${PROVIDER_ID}"

    # ── Poll SSM until master uploads the join token ──────────────────────────
    echo "Polling SSM for join command..."
    while true; do
      SSM_VALUE=$(aws ssm get-parameter \
        --name "/${var.env}/k8s/join_token" \
        --with-decryption \
        --region "$AWS_REGION" \
        --query "Parameter.Value" \
        --output text 2>/dev/null || echo "failed")

      if [ "$SSM_VALUE" != "placeholder-awaiting-master-initialization" ] \
         && [ "$SSM_VALUE" != "failed" ] \
         && [ -n "$SSM_VALUE" ]; then
        echo "Join token retrieved."
        break
      fi
      echo "Waiting for master to finish initialising..."
      sleep 15
    done

    # ── Parse token, CA hash, and API endpoint from the raw join command ──────
    TOKEN=$(echo "$SSM_VALUE"        | grep -oP '(?<=--token )\S+')
    CA_HASH=$(echo "$SSM_VALUE"      | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
    API_ENDPOINT=$(echo "$SSM_VALUE" | grep -oP '(?<=kubeadm join )\S+')

    echo "Parsed: endpoint=$${API_ENDPOINT} token=$${TOKEN} ca=$${CA_HASH}"

    cat <<EOF > /tmp/kubeadm-join.yaml
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: JoinConfiguration
    discovery:
      bootstrapToken:
        apiServerEndpoint: "$${API_ENDPOINT}"
        token: "$${TOKEN}"
        caCertHashes:
          - "$${CA_HASH}"
    nodeRegistration:
      kubeletExtraArgs:
        cloud-provider: "external"
        provider-id: "$${PROVIDER_ID}"
    EOF

    echo "Joining cluster with provider-id=$${PROVIDER_ID} ..."
    kubeadm join --config /tmp/kubeadm-join.yaml
  WORKER
}

output "master_userdata" {
  value = "${local.common}\n${local.master_init}"
}

output "worker_userdata" {
  value = "${local.common}\n${local.worker_join}"
}
