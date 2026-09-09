# ============================================================================
# CONTRATO DE OUTPUTS — consumido pelos repos a jusante via terraform_remote_state
# ============================================================================
#
# Este arquivo E o contrato entre os repositorios da Fase 3. Consumidores:
#
#   workshop-infra-database   -> vpc_id, private_subnet_ids, db_client_sg_id, vpc_cidr
#   workshop-auth-serverless  -> vpc_id, private_subnet_ids, db_client_sg_id
#
# REGRA: remover ou renomear um output aqui QUEBRA o `plan` dos repos a jusante.
# Adicionar e seguro. Renomear exige PR coordenado nos dois repos, na mesma janela.
#
# Nenhum segredo trafega por aqui. A senha do banco vive em Environment secret,
# consumida igualmente pelo k8s Secret e pela Lambda — nunca por remote state.

# --- Rede ---
output "vpc_id" {
  description = "Id da VPC. Consumido por: database, serverless."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR da VPC. Consumido por: database (ingress por CIDR, se necessario)."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Subnets privadas. Consumido por: database (subnet group), serverless (Lambda em VPC)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Subnets publicas (NAT). Nao usar para workloads."
  value       = module.vpc.public_subnets
}

output "availability_zones" {
  description = "AZs em uso, na mesma ordem das subnets."
  value       = module.vpc.azs
}

# --- Cluster ---
output "cluster_name" {
  description = "Nome do cluster EKS. Usado em `aws eks update-kubeconfig`."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint da API do EKS. Consumido por: pipelines de deploy."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "CA do cluster, base64. Par do cluster_endpoint para montar kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Versao do control plane em uso."
  value       = aws_eks_cluster.this.version
}

output "node_security_group_id" {
  description = "SG primario do cluster, tambem anexado aos nodes gerenciados. Alternativa direta ao db_client_sg_id (ver ADR-005)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# --- Identidade de cliente do banco ---
output "db_client_sg_id" {
  description = <<-DESC
    SG de identidade dos clientes do RDS. O repo workshop-infra-database autoriza
    ESTE id no ingress 5432, sem conhecer nada mais do cluster.
  DESC
  value       = aws_security_group.db_client.id
}

# --- Academy ---
output "lab_role_arn" {
  description = "ARN da LabRole. Consumido por: serverless (execution role da Lambda)."
  value       = data.aws_iam_role.lab.arn
}

# --- Fallback do §4: se o backend S3 for bloqueado no Academy, a pipeline publica
# este mapa como contracts/outputs.json (artifact) e os repos a jusante o consomem
# como var, em vez de terraform_remote_state. Ver ADR-005.
output "contract" {
  description = "Contrato completo em um unico mapa, para publicacao como artifact."
  value = {
    vpc_id                 = module.vpc.vpc_id
    vpc_cidr               = module.vpc.vpc_cidr_block
    private_subnet_ids     = module.vpc.private_subnets
    public_subnet_ids      = module.vpc.public_subnets
    availability_zones     = module.vpc.azs
    cluster_name           = aws_eks_cluster.this.name
    cluster_endpoint       = aws_eks_cluster.this.endpoint
    cluster_version        = aws_eks_cluster.this.version
    node_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    db_client_sg_id        = aws_security_group.db_client.id
    lab_role_arn           = data.aws_iam_role.lab.arn
  }
}
