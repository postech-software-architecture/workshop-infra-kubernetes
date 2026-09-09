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

  # Backend S3 + lock DynamoDB: criado UMA vez, fora dos 4 states (ver docs/backend.md).
  # Comentado ate o spike da W0 confirmar que o Academy permite S3+DynamoDB.
  # backend "s3" {
  #   bucket         = "soat-tc3-tfstate"
  #   key            = "cluster/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "soat-tc3-tflock"
  #   encrypt        = true
  # }
}
