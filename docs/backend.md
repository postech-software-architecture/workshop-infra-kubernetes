# Backend remoto do Terraform

O state do cluster fica em:

    s3://soat-tc3-tfstate-mateus-paz/cluster/terraform.tfstate

O lock usa a tabela DynamoDB soat-tc3-tflock, com partition key LockID
do tipo String. Ambos vivem em us-east-1.

## Bootstrap

O bucket e a tabela sao criados uma vez, fora deste state. Configuracao obrigatoria:

- bucket privado, ACLs desabilitadas e Block Public Access ativo;
- versionamento e criptografia SSE-S3 ativos;
- tabela DynamoDB em modo on-demand e estado ACTIVE.

Os workflows de apply e destroy verificam, antes do `terraform init`, que o bucket
existe, tem versionamento `Enabled`, criptografia server-side e as quatro flags do
Block Public Access ativas. Tambem exigem a tabela DynamoDB em estado `ACTIVE`.
Eles nao tentam criar esses recursos, evitando que o Terraform dependa de um backend
que ainda nao existe ou use um state sem as protecoes acordadas.

## Operacao

- CI — Terraform: em todo push/PR executa somente fmt, validate e politicas, sem
  credenciais AWS e sem acesso ao backend;
- Terraform — Apply EKS: manual, somente na `main`, exige APLICAR-PROD e aprovacao do
  Environment. O mesmo run gera o plan, valida sua fronteira pelo JSON e bloqueia delete
  ou replacement. A unica excecao e o replacement isolado do node group, com o input
  separado `SUBSTITUIR-NODE-GROUP-COM-DOWNTIME-E-CUSTO`;
- Terraform — Destroy EKS: manual, exige DESTRUIR-PROD, remove load balancers
  externos ao state e preserva bucket, tabela e state. Antes de qualquer remocao,
  bloqueia se `db_client_sg_id` ainda estiver associado a Lambda ou ENI externa ao
  managed node group deste state.

As tres operacoes usam o mesmo grupo de concorrencia para impedir alteracoes
simultaneas no state.

## Recuperacao

Se uma execucao for interrompida, nao apague bucket, tabela ou lock manualmente.
Primeiro confirme que nao ha outro workflow em andamento. Depois execute
terraform plan, revise o resultado e execute terraform apply para concluir a
reconciliacao entre state e AWS. Use uma versao anterior do objeto S3 somente
quando houver evidencia de corrupcao do state.
