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

A CI de PR verifica formato, validade e politicas sem credenciais AWS. O plan real e
executado somente pelo workflow manual de apply, depois do merge em `main`; nele a
fronteira e verificada sobre o JSON do plan e falha se algum `aws_db_*` aparecer.

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

### Acesso EKS -> RDS

O launch template dos managed nodes anexa simultaneamente:

- o security group primario do cluster, necessario para a comunicacao entre control
  plane, nodes e workloads do EKS;
- o `db_client_sg_id`, usado exclusivamente como identidade no ingress 5432 do RDS.

O repositorio de banco deve autorizar `db_client_sg_id` no security group do RDS. Este
repositorio nao cria nem altera recursos `aws_db_*`.

Com o state vazio apos um destroy, o proximo apply cria o launch template e o node group
ja com os dois SGs; nao existe replacement. Se ainda houver um ambiente criado antes desta
mudanca, o Terraform deve mostrar a **substituicao de `aws_eks_node_group.default`**, pois
nao e possivel adicionar um launch template a um managed node group existente. O control
plane, a VPC e os security groups permanecem. Nesse segundo cenario, planeje uma janela
sem dependencia de workloads; o ambiente Academy pode ficar temporariamente sem nodes
enquanto o novo grupo e criado. Depois, mudancas na versao do launch template usam rolling
update com `max_unavailable = 1`.

Antes de aprovar o plan, confirme:

```text
aws_launch_template.eks_nodes: create
state vazio: aws_eks_node_group.default sera criado com launch_template
ambiente legado: aws_eks_node_group.default tera replacement por adicao de launch_template
aws_eks_cluster.this e aws_security_group.db_client: sem replacement no ambiente legado
zero recursos aws_db_*
```

O workflow `Terraform — Apply EKS` bloqueia qualquer delete ou replacement por padrao.
A unica excecao e a substituicao isolada de `aws_eks_node_group.default`, quando o state
legado ainda possui o node group sem launch template. Para autoriza-la, alem de
`APLICAR-PROD`, preencha o input separado com o texto exato
`SUBSTITUIR-NODE-GROUP-COM-DOWNTIME-E-CUSTO`. Essa opcao implica janela sem nodes,
indisponibilidade dos workloads e possivel custo temporario durante a troca. Com state
vazio, deixe esse segundo input em branco: o plan esperado contem apenas criacoes.

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
  convencional, usar IRSA ou EKS Pod Identity. O fallback usa uma replica e rollout
  `Recreate` para nao disputar portas do host
- **Sempre `terraform destroy` ao final da sessao**

## Pendencias

- Confirmar no `terraform plan` real se o node group sera criado (state vazio) ou
  substituido (ambiente legado) antes do apply
- Executar o plan real somente na `main`, pelo workflow manual protegido pelo Environment
  `prod`; PRs nunca recebem credenciais AWS

## Agentes

Ver [.claude/agents/README.md](.claude/agents/README.md). Dono: `terraform-cluster`.
