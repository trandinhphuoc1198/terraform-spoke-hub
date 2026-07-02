terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket       = "terraform-state-phuoctd6"
    key          = "hub/dev/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# One-directional only: global/network has no dependency back on hub or
# spoke, so this is safe to read any time as long as global/network was
# applied first (see root README for apply order).
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "terraform-state-phuoctd6"
    key    = "global/network/terraform.tfstate"
    region = "ap-northeast-1"
  }
}
