terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  # Bootstrap criado fora deste state. Assim o destroy do EKS preserva a memoria
  # necessaria para execucoes futuras (ver docs/backend.md).
  backend "s3" {
    bucket         = "soat-tc3-tfstate-mateus-paz"
    key            = "cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "soat-tc3-tflock"
    encrypt        = true
  }
}
