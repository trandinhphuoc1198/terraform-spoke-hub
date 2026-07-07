# ── CIDR overlap guard ─────────────────────────────────────────────────────
# See live/hub/main.tf for why this exists — same logic, mirrored here.
locals {
  cidr_ranges = {
    for c in [var.vpc_cidr, var.hub_vpc_cidr] : c => {
      start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
      end   = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", c)[1])) - 1
    }
  }
}

check "no_cidr_overlap" {
  assert {
    condition = !(
      local.cidr_ranges[var.vpc_cidr].start <= local.cidr_ranges[var.hub_vpc_cidr].end &&
      local.cidr_ranges[var.hub_vpc_cidr].start <= local.cidr_ranges[var.vpc_cidr].end
    )
    error_message = "vpc_cidr (${var.vpc_cidr}) and hub_vpc_cidr (${var.hub_vpc_cidr}) overlap — they must be disjoint for TGW routing to work."
  }
}

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

  triggers = {
    nat_instance_id = module.vpc.nat_instance_id
  }

  # See live/hub/main.tf for the rationale on this provisioner.
  provisioner "local-exec" {
    command    = "aws ec2 wait instance-status-ok --instance-ids ${module.vpc.nat_instance_id} --region ${var.region}"
    on_failure = continue
  }
}

# ── Baked k8s base AMI (built by Packer + Ansible — see /packer) ─────────────
# Shared by both the master (module.ec2) and workers (module.asg) below.
module "ami" {
  source = "../../modules/ami"
}

# ── Transit Gateway attachment — connects this VPC to the hub VPC ────────────
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                   = var.env
  transit_gateway_id    = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                = module.vpc.vpc_id
  attachment_subnet_ids = module.vpc.private_subnet_ids
  route_table_ids       = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks      = [var.hub_vpc_cidr]
}

# ── K8s bootstrap scripts (CNI + CCM only — no Argo CD on a spoke) ────────────
module "k8s" {
  source            = "../../modules/k8s"
  k8s_version       = var.k8s_version
  pod_cidr          = var.pod_cidr
  env               = var.env
  cluster_name      = var.cluster_name
  cni_manifest_url  = var.cni_manifest_url
  install_argocd    = false
  register_with_hub = true
}

# ── EC2: master node + shared IAM/SG resources ────────────────────────────────
module "ec2" {
  source                  = "../../modules/ec2"
  env                     = var.env
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_subnet_ids      = module.vpc.private_subnet_ids
  public_subnet_ids       = module.vpc.public_subnet_ids
  master_instance_type    = var.master_instance_type
  key_name                = var.key_name
  master_private_ip       = var.master_private_ip
  alb_sg_id               = module.alb.alb_sg_id
  k8s_bootstrap           = module.k8s.master_userdata
  cluster_name            = var.cluster_name
  ami_id                  = module.ami.ami_id
  trusted_api_cidr_blocks = [var.hub_vpc_cidr]
  s3_bucket_arns          = module.s3.bucket_arns
  register_with_hub       = true
}

# ── ASG: worker node Auto Scaling Group ───────────────────────────────────────
module "asg" {
  source                           = "../../modules/asg"
  env                              = var.env
  cluster_name                     = var.cluster_name
  worker_instance_type             = var.worker_instance_type
  key_name                         = var.key_name
  private_subnet_ids               = module.vpc.private_subnet_ids
  worker_sg_id                     = module.ec2.worker_sg_id
  worker_iam_instance_profile_name = module.ec2.worker_iam_instance_profile_name
  k8s_worker_bootstrap             = module.k8s.worker_userdata
  worker_min                       = var.worker_min
  worker_max                       = var.worker_max
  worker_desired                   = var.worker_desired
  worker_volume_size               = var.worker_volume_size
  ami_id                           = module.ami.ami_id

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
