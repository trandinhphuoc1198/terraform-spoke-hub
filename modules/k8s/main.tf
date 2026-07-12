output "master_userdata" {
  value = templatefile("${path.module}/templates/master_init.sh.tpl", {
    k8s_version      = var.k8s_version
    pod_cidr         = var.pod_cidr
    cni_manifest_url = var.cni_manifest_url
    env              = var.env
  })
}

output "worker_userdata" {
  value = templatefile("${path.module}/templates/worker_init.sh.tpl", {
    env = var.env
  })
}