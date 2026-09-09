# Repositorio de infraestrutura Kubernetes — Fase 3.
#
# Escopo deste repo: VPC, EKS, node group, metrics-server e AWS Load Balancer Controller.
# NAO existe nenhum recurso aws_db_* aqui — o banco vive em workshop-infra-database, com
# state proprio. O `plan` deste repo sem nenhum aws_db_* e criterio do gate G3.
#
# AWS Academy: LabRole e a unica role usavel (IAM bloqueado) e as credenciais expiram
# em ~4h (AWS Details inclui aws_session_token). Sempre `terraform destroy` ao final.

data "aws_availability_zones" "available" {
  state = "available"
}

# LabRole pre-existente do Academy — unica role usavel.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "aws_caller_identity" "current" {}

# --- Rede ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true # reduz custo (NAT Gateway e caro)

  # Tags exigidas pelo AWS Load Balancer Controller para descobrir subnets.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = { Project = var.project }
}

# --- Cluster EKS ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Academy: nao criar IAM role do cluster — reusar a LabRole.
  create_iam_role = false
  iam_role_arn    = data.aws_iam_role.lab.arn

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    lab = {
      principal_arn = data.aws_iam_role.lab.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # Academy: nodes tambem reusam a LabRole.
      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.lab.arn
    }
  }

  tags = { Project = var.project }
}

# --- metrics-server (o HPA da aplicacao le CPU daqui) ---
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.eks]
}

# --- AWS Load Balancer Controller ---
# Instalado nesta onda (W2) porque a W4-B precisa dele para criar o NLB interno que o
# VPC Link do API Gateway consome. Sem o controller, um Service type=LoadBalancer fica
# em <pending> para sempre.
#
# Academy: sem IRSA (nao ha permissao para criar IAM role/OIDC provider). O controller
# usa as permissoes da LabRole herdadas pelo node — por isso serviceAccount.create=true
# sem annotation de role.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  depends_on = [module.eks, helm_release.metrics_server]
}

# --- Security group de CLIENTE do banco ---
# Este SG nao abre nada: e apenas a identidade que o repo do banco autoriza no ingress
# 5432. Vive aqui (e nao no repo do banco) porque quem o consome sao os nodes do EKS, e
# assim o repo do banco nao precisa conhecer nada do cluster alem deste id.
resource "aws_security_group" "db_client" {
  name        = "${var.project}-db-client-sg"
  description = "Identidade dos clientes do RDS (nodes do EKS e Lambda). Sem regras de ingress."
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Saida para o RDS na porta do Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Project = var.project }
}

# NOTA (W3): o SG de cliente precisa estar anexado aos nodes para os pods o herdarem.
# O modulo EKS ja permite isso via `node_security_group_additional_rules`, mas anexar um
# SG extra ao node group exige `vpc_security_group_ids` no launch template — mudanca que
# recria os nodes. Fica para a W3, junto com o ingress do lado do banco, para nao recriar
# o cluster duas vezes. Alternativa avaliada: usar direto `module.eks.node_security_group_id`
# como cliente autorizado (output abaixo), dispensando este SG. A decisao vai no ADR-005.
