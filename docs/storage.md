# Armazenamento EBS automatizado no AWS Academy

O workflow `Terraform — Apply EKS` instala o add-on gerenciado `aws-ebs-csi-driver`
e cria a StorageClass `soat-ebs-gp3`. A mesma execucao verifica o funcionamento com
um PVC/Pod temporarios, faz escrita/leitura e confere a remocao do volume de prova.
Nao e necessario cadastrar manualmente o complemento a cada recriacao do lab.

## Recursos e contrato

- `aws_eks_addon.ebs_csi`: instalado depois do node group. Por padrao seleciona a
  versao default compativel com `cluster_version` recomendada pela AWS. A Variable
  opcional `EBS_CSI_ADDON_VERSION` do Environment `prod` permite fixa-la. O output
  `ebs_csi_addon_version` informa a versao efetiva; registrar/fixar esse valor permite
  evitar alteracoes de versao quando a AWS muda sua recomendacao.
- `kubernetes_storage_class_v1.ebs_gp3`: provisioner `ebs.csi.aws.com`, tipo gp3,
  criptografia habilitada, expansao permitida e `WaitForFirstConsumer`. A selecao da
  AZ considera o Pod consumidor. Nao altera a StorageClass default do cluster.
- `storage_class_name`: output adicional, com valor `soat-ebs-gp3`. Usar esse nome
  na Variable `STORAGE_CLASS` do Environment `prod` de `workshop-infra-platform`.

Os enderecos e outputs anteriores permanecem. No cluster ja criado, o plan esperado
adiciona somente o add-on e a StorageClass, sem substituir VPC/EKS/node group. Ler
o plan real antes de considerar essa expectativa comprovada. Os gates de fronteira
e de alteracoes destrutivas continuam ativos.

## Permissoes Academy

Os nodes ja usam `LabRole`; o launch template preserva IMDSv2 e hop limit 2. O add-on
nao recebe `service_account_role_arn` nem associacao Pod Identity. Assim utiliza as
permissoes da role dos nodes, conforme o fallback documentado na API da AWS.
Esta e uma concessao especifica do Academy. Em uma conta convencional, preferir
uma identidade de workload com permissoes restritas ao driver.

Este Terraform nao cria IAM role/policy, nao anexa policies e nao modifica a trust
policy da LabRole. A role existente precisa permitir as operacoes EC2 do driver
para criar/anexar/remover EBS. Um lab diferente pode restringir essas permissoes.
O teste real de PVC e o criterio de funcionamento: status `ACTIVE` do add-on,
isoladamente, nao comprova permissao de criar volume.

Se ocorrer `UnauthorizedOperation` ou outro bloqueio, conferir os eventos da prova
e as permissoes permitidas pelo lab. Interromper a implantacao dos bancos ate
resolver essa restricao dentro do que o Academy autoriza; nao adicionar IAM ou
trocar por armazenamento efemero para declarar sucesso.

Referencias: [CreateAddon e fallback para a role dos nodes](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreateAddon.html)
e [requisitos do EBS CSI](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html).

## Validacao automatica depois do apply

`.github/scripts/validate-storage.sh`:

1. Confirma o add-on `ACTIVE`, o rollout de controller/DaemonSet e o CSIDriver.
2. Confere os atributos da StorageClass gerenciada.
3. Cria um namespace exclusivo `soat-storage-check-<run>-<attempt>`, um PVC de 1 GiB
   e um Pod sem token de ServiceAccount, com imagem BusyBox versionada.
4. Espera PVC `Bound` e Pod `Succeeded`; o Pod escreve e le um marcador no volume.
5. Confere na API EC2 que o volume e gp3 criptografado.
6. Remove o namespace temporario e aguarda a ausencia do volume na API EC2. Se a
   prova falhar, exibe somente eventos/objetos desse namespace. Falha de limpeza
   tambem falha o workflow e informa qual volume requer conferencia.

Nenhum PVC, Pod ou volume das aplicacoes participa dessa prova. Uma falha depois
do apply nao desfaz automaticamente a infraestrutura que o Terraform ja criou:
conferir a causa e a limpeza antes de repetir. Nenhuma credencial entra no log.

## Adocao e ciclo de vida

Se o complemento ou a classe ja tiverem sido criados manualmente, conferir seus
atributos e importar os objetos corretos antes do apply. A criacao usa conflito
`NONE`; atualizacoes usam `PRESERVE`. Nao sobrescrever/adotar uma instalacao
desconhecida automaticamente.

```bash
terraform import aws_eks_addon.ebs_csi workshop-eks:aws-ebs-csi-driver
terraform import kubernetes_storage_class_v1.ebs_gp3 soat-ebs-gp3
terraform plan
```

Esses imports sao somente para objetos comprovadamente existentes. O caminho atual
com zero complementos e sem essa StorageClass e criacao nova, sem import.

A politica de reclaim da classe e `Delete`: excluir um PVC pode apagar seu EBS.
Backup/restauracao e remocao de dados devem ser deliberados. Excluir a StorageClass
nao exclui automaticamente os PVCs/volumes que ja existem. O workflow de destroy
bloqueia a remocao do driver/cluster enquanto houver PVs EBS de workloads, antes de
limpar os load balancers. Concluir backup e remocao dos consumidores antes de
executar o destroy da fundacao.

## Estado da validacao desta alteracao

Fmt/validate/CI comprovam a configuracao; o teste de volume so e comprovado quando
o workflow de apply com esta alteracao executar no lab e concluir. Nao tratar a
criacao anterior do cluster ou a abertura do PR como prova desse novo armazenamento.
