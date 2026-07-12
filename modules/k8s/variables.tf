variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. 1.29)"
}

variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR passed to kubeadm --pod-network-cidr"
}

variable "env" {
  type        = string
  description = "The target deployment environment/cluster name (e.g. hub-dev, spoke-dev)"
}

variable "cni_manifest_url" {
  type        = string
  description = "Manifest URL applied right after kubeadm init to bring up pod networking"
  default     = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
}

# NOTE: install_argocd, argocd_namespace, argocd_chart_version, install_eso,
# register_with_hub, cluster_name, and gitops_repo_raw_url were removed here.
# This module's only job now is "produce a script that gets kubeadm to a
# Ready node with CNI." Argo CD/CCM/ESO installation and hub registration
# move to CI-driven bootstrap steps (see .github/workflows/) and, later,
# Argo CD Applications in the gitops repo.