# Renders kubeadm bootstrap scripts passed into EC2 user_data.
#
# Every master (hub AND every spoke) gets: kubeadm init, CNI, and CCM —
# these three are what "makes the cluster alive" and none of them can be
# installed by Argo CD, since nothing schedules until they're running.
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

    # ── Install utilities ─────────────────────────────────────────────────────
    yum install -y jq

    # ── Disable swap ──────────────────────────────────────────────────────────
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    # ── Kernel modules required by containerd / k8s ───────────────────────────
    sudo modprobe br_netfilter
    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF
    modprobe overlay
    modprobe br_netfilter

    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
    sysctl --system

    # ── containerd ────────────────────────────────────────────────────────────
    yum install -y containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl enable --now containerd

    # ── kubeadm / kubelet / kubectl ───────────────────────────────────────────
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
    [kubernetes]
    name=Kubernetes
    baseurl=https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/rpm/
    enabled=1
    gpgcheck=1
    gpgkey=https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/rpm/repodata/repomd.xml.key
    EOF

    yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    systemctl enable --now kubelet
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

    # ── CNI (required — no pod, including CCM/Argo CD, schedules without it) ──
    echo "=== Installing CNI ===" >> /var/log/kubeadm-init.log
    kubectl apply -f ${var.cni_manifest_url}

    # ── AWS Cloud Controller Manager (required — removes the node's ─────────
    #    "uninitialized" taint so anything else can schedule at all) ──────────
    echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
    helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
    helm repo update

    helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
      --namespace kube-system \
      --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=false}'

    echo "=== Waiting for node to become Ready ===" >> /var/log/kubeadm-init.log
    kubectl wait node --all --for=condition=Ready --timeout=300s

    %{ if var.install_argocd ~}
    # ── Argo CD (hub only) ────────────────────────────────────────────────────
    # This is the ONLY application-layer thing Terraform installs, because the
    # hub cluster's entire purpose is to run it. Actual Application / AppProject
    # manifests that Argo CD then syncs live in a separate GitOps repo — not here.
    echo "=== Installing Argo CD ===" >> /var/log/kubeadm-init.log
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    helm upgrade --install argocd argo/argo-cd \
      --namespace ${var.argocd_namespace} \
      --create-namespace \
      %{ if var.argocd_chart_version != "" ~}
      --version "${var.argocd_chart_version}" \
      %{ endif ~}
      --set configs.params."server\.insecure"=true
    %{ endif ~}

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
