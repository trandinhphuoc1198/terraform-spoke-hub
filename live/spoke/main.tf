# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source               = "../../modules/vpc"
  env                  = var.env
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  region               = var.region
}

resource "null_resource" "wait_for_nat" {
  depends_on = [module.vpc]

  provisioner "local-exec" {
    command = "aws ec2 wait instance-status-ok --instance-ids ${module.vpc.nat_instance_id}"
  }
}

# ── Transit Gateway attachment — connects this VPC to the hub VPC ────────────
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                    = var.env
  transit_gateway_id     = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                 = module.vpc.vpc_id
  attachment_subnet_ids  = module.vpc.private_subnet_ids
  route_table_ids        = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks       = [var.hub_vpc_cidr]
}

# ── K8s bootstrap scripts (CNI + CCM only — no Argo CD on a spoke) ────────────
module "k8s" {
  source          = "../../modules/k8s"
  k8s_version      = var.k8s_version
  pod_cidr         = var.pod_cidr
  env              = var.env
  cni_manifest_url  = var.cni_manifest_url
  install_argocd    = false # spokes are managed BY Argo CD, never run it
}

# ── EC2: master node + shared IAM/SG resources ────────────────────────────────
module "ec2" {
  source                   = "../../modules/ec2"
  env                      = var.env
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  public_subnet_ids        = module.vpc.public_subnet_ids
  master_instance_type     = var.master_instance_type
  key_name                 = var.key_name
  master_private_ip        = var.master_private_ip
  alb_sg_id                = module.alb.alb_sg_id
  k8s_bootstrap             = module.k8s.master_userdata
  cluster_name              = var.cluster_name
  # Lets the hub's Argo CD reach this cluster's kube-apiserver over the TGW
  # to register it as a remote cluster and start syncing workloads.
  trusted_api_cidr_blocks   = [var.hub_vpc_cidr]
}

# ── ASG: worker node Auto Scaling Group ───────────────────────────────────────
module "asg" {
  source                            = "../../modules/asg"
  env                               = var.env
  cluster_name                      = var.cluster_name
  worker_instance_type              = var.worker_instance_type
  key_name                          = var.key_name
  private_subnet_ids                = module.vpc.private_subnet_ids
  worker_sg_id                      = module.ec2.worker_sg_id
  worker_iam_instance_profile_name  = module.ec2.worker_iam_instance_profile_name
  k8s_worker_bootstrap               = module.k8s.worker_userdata
  worker_min                         = var.worker_min
  worker_max                         = var.worker_max
  worker_desired                     = var.worker_desired
  worker_volume_size                 = var.worker_volume_size

  depends_on = [module.vpc, null_resource.wait_for_nat]
}

# ── ALB — app workloads (NOT Argo CD — that's on the hub's ALB now) ──────────
module "alb" {
  source            = "../../modules/alb"
  env               = var.env
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  https_nodeport    = var.https_nodeport
  worker_sg_id      = module.ec2.worker_sg_id
  asg_name          = module.asg.asg_name
  certificate_arn   = var.certificate_arn
  apps              = var.apps
}

# ── S3 Buckets ─────────────────────────────────────────────────────────────────
module "s3" {
  source       = "../../modules/s3"
  bucket_names = var.bucket_names
  env          = var.env
}
