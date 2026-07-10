output "master_userdata" {
  value = templatefile("${path.module}/templates/master_init.sh.tpl", {
    k8s_version          = var.k8s_version
    pod_cidr             = var.pod_cidr
    install_argocd       = var.install_argocd
    argocd_namespace     = var.argocd_namespace
    argocd_chart_version = var.argocd_chart_version
    cni_manifest_url     = var.cni_manifest_url
    install_eso          = var.install_eso
    env                  = var.env
    register_with_hub    = var.register_with_hub
    cluster_name         = var.cluster_name
    gitops_repo_raw_url  = var.gitops_repo_raw_url
  })
}

output "worker_userdata" {
  value = templatefile("${path.module}/templates/worker_init.sh.tpl", {
    env = var.env
  })
}