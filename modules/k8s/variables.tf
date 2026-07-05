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

variable "install_argocd" {
  type        = bool
  description = "Whether this master should bootstrap Argo CD. true for the hub cluster, false for every spoke — spokes are only ever managed BY Argo CD, never run it."
  default     = false
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  description = "Pin the argo-cd Helm chart version. Leave empty to track latest (not recommended for prod)."
  type        = string
  default     = ""
}

variable "cluster_name" {
  type        = string
  description = "K8s cluster name — used as the key under argocd-clusters/ in Secrets Manager when register_with_hub is true"
  default     = ""
}

variable "register_with_hub" {
  type        = bool
  description = "If true, master bootstrap creates an argocd-manager SA/token and pushes it to Secrets Manager for the hub's Argo CD to discover. Spokes only."
  default     = false
}

variable "install_eso" {
  type        = bool
  description = "If true, master bootstrap installs External Secrets Operator and wires a ClusterSecretStore to AWS Secrets Manager. Hub only."
  default     = false
}