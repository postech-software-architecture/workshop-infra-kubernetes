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
  # Backend parcial: bucket, region e dynamodb_table chegam por -backend-config
  # no init, a partir das variables TFSTATE_BUCKET e TFSTATE_LOCK_TABLE do
  # Environment. Um bloco backend nao aceita interpolacao, entao esta e a unica
  # forma de nao fixar o nome da conta no codigo.
  backend "s3" {
    key     = "cluster/terraform.tfstate"
    encrypt = true
  }
}
