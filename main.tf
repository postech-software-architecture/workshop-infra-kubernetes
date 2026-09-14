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
# O modulo terraform-aws-modules/eks consulta iam:GetRole para descobrir a role
# emissora da sessao STS (voclabs). A policy Pvoclabs2 do Academy nega essa
# introspeccao explicitamente. Recursos AWS diretos evitam a chamada e preservam
# a implementacao ja validada no workshop-service-fase1.
resource "aws_eks_cluster" "this" {
  name     = "${var.project}-eks"
  version  = var.cluster_version
  role_arn = data.aws_iam_role.lab.arn

  vpc_config {
    subnet_ids              = concat(module.vpc.private_subnets, module.vpc.public_subnets)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = { Project = var.project }

  depends_on = [module.vpc]
}

# --- Security group de CLIENTE do banco ---
# Este SG nao abre nada: e apenas a identidade que o repo do banco autoriza no ingress
# 5432. Vive aqui (e nao no repo do banco) porque quem o consome sao os nodes do EKS e a
# Lambda. Assim o repo do banco nao precisa conhecer os clientes alem deste id.
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

# Quando um managed node group usa security groups em um launch template, o EKS deixa
# de anexar automaticamente o cluster security group. Por isso a lista abaixo preserva
# explicitamente o SG primario do cluster e acrescenta o SG que identifica clientes do
# banco. O primeiro apply desta mudanca substitui o node group legado (sem launch
# template); alteracoes futuras de versao fazem um rolling update dos nodes.
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.project}-eks-node-"
  description = "Launch template dos managed nodes com identidades EKS e RDS"

  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    aws_security_group.db_client.id,
  ]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project}-eks-node"
      Project = var.project
    }
  }

  tags = { Project = var.project }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = data.aws_iam_role.lab.arn
  subnet_ids      = module.vpc.private_subnets
  version         = var.cluster_version

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  instance_types = var.node_instance_types

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = tostring(aws_launch_template.eks_nodes.latest_version)
  }

  update_config {
    max_unavailable = 1
  }

  tags = { Project = var.project }

  depends_on = [aws_eks_cluster.this]
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

  depends_on = [aws_eks_node_group.default]
}

# --- AWS Load Balancer Controller ---
# Instalado nesta onda (W2) porque a W4-B precisa dele para criar o NLB interno que o
# VPC Link do API Gateway consome. Sem o controller, um Service type=LoadBalancer fica
# em <pending> para sempre.
#
# Academy: sem IRSA (nao ha permissao para criar IAM role/OIDC provider). O controller
# usa as permissoes da LabRole herdadas pelo node. O hop limit do IMDS bloqueia pods
# na rede comum, portanto somente este controller roda em hostNetwork. Em uma conta
# AWS convencional, substituir por IRSA/Pod Identity e remover essa excecao.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
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

  set {
    name  = "hostNetwork"
    value = "true"
  }

  set {
    name  = "dnsPolicy"
    value = "ClusterFirstWithHostNet"
  }

  # hostNetwork torna as portas do controller exclusivas por node. Uma replica com
  # Recreate evita colisao durante rollout e tambem funciona com node_min_size = 1.
  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "updateStrategy.type"
    value = "Recreate"
  }

  depends_on = [aws_eks_node_group.default, helm_release.metrics_server]
}

# --- NRDOT Collector (W5) ---
# O chart oficial da New Relic instala a distribuicao NRDOT e seus componentes de
# descoberta Kubernetes. O license key entra somente por TF_VAR_new_relic_license_key
# no environment prod; nao existe segredo em values versionados.
resource "kubernetes_namespace" "new_relic" {
  metadata {
    name = "newrelic"
  }

  depends_on = [aws_eks_node_group.default]
}

resource "kubernetes_secret" "new_relic_license" {
  count = var.new_relic_license_key == null ? 0 : 1

  metadata {
    name      = "new-relic-license"
    namespace = "newrelic"
  }

  type = "Opaque"

  # O provider kubernetes 2.x aceita o mapa data em base64. O valor continua
  # vindo exclusivamente do secret sensivel do Environment prod.
  data = {
    licenseKey = base64encode(var.new_relic_license_key)
  }

  depends_on = [kubernetes_namespace.new_relic]
}

resource "helm_release" "nrdot_collector" {
  name             = "nr-k8s-otel-collector"
  namespace        = "newrelic"
  create_namespace = true
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nr-k8s-otel-collector"
  version          = var.new_relic_collector_chart_version

  # O chart disponibiliza a chave via Secret referenciado, sem expor o valor no
  # release values. Sem a chave o apply falha explicitamente no precondition.
  values = [yamlencode({
    cluster                = aws_eks_cluster.this.name
    customSecretName       = "new-relic-license"
    customSecretLicenseKey = "licenseKey"
    images = {
      collector = {
        repository = "newrelic/nrdot-collector"
        tag        = var.new_relic_collector_image_tag
      }
    }
    deployment = {
      enabled = true
      configMap = {
        extraConfig = {
          processors = {
            resource_workshop = {
              attributes = [
                {
                  key    = "deployment.environment"
                  value  = "prod"
                  action = "insert"
                },
                {
                  key    = "service.name"
                  value  = "workshop-eks"
                  action = "insert"
                }
              ]
            }
            batch_workshop = {
              timeout         = "5s"
              send_batch_size = 256
            }
          }
          pipelines = {
            "traces/workshop" = {
              receivers  = ["otlp"]
              processors = ["memory_limiter", "resource_workshop", "batch_workshop"]
              exporters  = ["otlp_http/newrelic"]
            }
            "metrics/workshop" = {
              receivers  = ["otlp"]
              processors = ["memory_limiter", "resource_workshop", "batch_workshop"]
              exporters  = ["otlp_http/newrelic"]
            }
            "logs/workshop" = {
              receivers  = ["otlp"]
              processors = ["memory_limiter", "resource_workshop", "batch_workshop"]
              exporters  = ["otlp_http/newrelic"]
            }
          }
        }
      }
    }
    daemonset = {
      enabled = true
    }
    receivers = {
      prometheus = {
        enabled = true
      }
      k8sEvents = {
        enabled = true
      }
      hostmetrics = {
        enabled = true
      }
      kubeletstats = {
        enabled = true
      }
      filelog = {
        enabled = true
      }
    }
  })]

  depends_on = [kubernetes_secret.new_relic_license, helm_release.aws_load_balancer_controller]

  lifecycle {
    precondition {
      condition     = var.new_relic_license_key != null && length(trimspace(var.new_relic_license_key)) >= 20
      error_message = "new_relic_license_key deve ser fornecida pelo secret prod e ter pelo menos 20 caracteres."
    }
  }
}

# O chart publica o gateway como <release>-gateway. A aplicacao W5 usa o nome
# estavel nr-k8s-otel-collector; este Service alias evita acoplamento ao sufixo
# interno do chart e encaminha somente para o Deployment gateway (OTLP).
resource "kubernetes_service" "nrdot_otlp_alias" {
  metadata {
    name      = "nr-k8s-otel-collector"
    namespace = "newrelic"
  }

  spec {
    selector = {
      "app.kubernetes.io/instance" = helm_release.nrdot_collector.name
      "app.kubernetes.io/name"     = "nr-k8s-otel-collector"
      component                    = "deployment"
    }

    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
      protocol    = "TCP"
    }

    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [helm_release.nrdot_collector]
}
