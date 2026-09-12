# workshop-infra-kubernetes

Infraestrutura Kubernetes da **Fase 3** do Tech Challenge (SOAT): VPC, EKS, node group,
`metrics-server` e AWS Load Balancer Controller.

Este repositorio **autora o contrato de outputs** consumido pelos repos de banco e
serverless. Nao contem nenhum recurso de banco de dados.

## Fronteira

| | |
|---|---|
| **Contem** | VPC, subnets, NAT, EKS, node group, metrics-server, LB Controller, SG de cliente do banco |
| **Nao contem** | Qualquer `aws_db_*` (vive em [workshop-infra-database](https://github.com/postech-software-architecture/workshop-infra-database)), manifestos k8s, Lambda/API Gateway |

A CI verifica essa fronteira: o job `plan` falha se algum `aws_db_*` aparecer.

## Contrato de outputs

`outputs.tf` **e** o contrato entre os repositorios. Consumidores:

| Output | database | serverless |
|---|---|---|
| `vpc_id` | sim | sim |
| `vpc_cidr` | sim | — |
| `private_subnet_ids` | sim (subnet group) | sim (Lambda em VPC) |
| `db_client_sg_id` | sim (ingress 5432) | sim |
| `cluster_endpoint` / `cluster_ca` | — | — (pipelines de deploy) |
| `lab_role_arn` | — | sim (execution role) |

**Remover ou renomear um output quebra o `plan` a jusante.** Adicionar e seguro;
renomear exige PR coordenado nos dois repos, na mesma janela.

Nenhum segredo trafega por output. A senha do banco vive em Environment secret,
consumida igualmente pelo k8s Secret e pela Lambda.

## Rodar

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate   # sem credencial

# com credencial do Academy (AWS Details -> inclui aws_session_token, expira ~4h)
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...
terraform init && terraform plan
terraform apply    # medido no Academy: ~16 min
terraform destroy  # ~10 min — SEMPRE ao final
```

Depois do apply:

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
kubectl get nodes                                    # Ready
kubectl -n kube-system get deploy metrics-server     # 1/1
kubectl -n kube-system get deploy aws-load-balancer-controller
```

O backend remoto e os workflows manuais de apply/destroy estao documentados em
[docs/backend.md](docs/backend.md). O bucket e a tabela de lock sao preservados
quando o EKS e destruido.

## AWS Academy

- `LabRole` e a **unica** role usavel (IAM bloqueado): cluster e nodes a reusam
- EKS usa recursos `aws_eks_cluster`/`aws_eks_node_group` diretos. O modulo EKS nao
  e compativel porque tenta consultar `iam:GetRole` da role de sessao `voclabs`
- A versao Kubernetes fica centralizada em `var.cluster_version` e aplicada igualmente
  ao control plane e ao node group; o baseline atual e `1.35`
- Credenciais expiram em **~4h** e incluem `aws_session_token`
- Sem IRSA — o LB Controller usa as permissoes herdadas pelo node e roda em
  `hostNetwork` para alcancar o IMDS. Esta e uma excecao do Academy; em uma conta
  convencional, usar IRSA ou EKS Pod Identity
- **Sempre `terraform destroy` ao final da sessao**

## Pendencias

- Anexo do `db_client_sg_id` aos nodes: W3 (ver nota no fim do `main.tf`)
- `plan` real na CI: depende dos secrets do Environment (`vars.AWS_CREDENTIALS_READY`)

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md). Dono: `terraform-cluster`.
