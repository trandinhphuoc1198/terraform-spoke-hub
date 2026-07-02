terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket       = "terraform-state-phuoctd6"
    key          = "spoke/dev/terraform.tfstate"
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

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "terraform-state-phuoctd6"
    key    = "global/network/terraform.tfstate"
    region = "ap-northeast-1"
  }
}
