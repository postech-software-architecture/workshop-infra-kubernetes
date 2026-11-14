# Persistencia da Fase 4. O Academy permite usar somente a LabRole existente.
# Sem service_account_role_arn/Pod Identity, o add-on usa a role dos nodes,
# que ja e data.aws_iam_role.lab. O IMDSv2/hop limit do launch template e preservado.
# Nenhuma IAM role, policy, trust policy ou associacao e criada/alterada aqui.
data "aws_eks_addon_version" "ebs_csi" {
  count = var.ebs_csi_addon_version == null ? 1 : 0

  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.cluster_version
  most_recent        = false
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.ebs_csi_addon_version != null ? var.ebs_csi_addon_version : data.aws_eks_addon_version.ebs_csi[0].version

  # Nao sobrescrever instalacoes manuais ou configuracoes desconhecidas.
  # Se o add-on ja existir fora do state, reconciliar/importar antes do apply.
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = { Project = var.project }

  depends_on = [aws_eks_node_group.default]
}

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "soat-ebs-gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # Nao muda a classe default do cluster. Consumidores selecionam pelo nome.
  depends_on = [aws_eks_addon.ebs_csi]
}
