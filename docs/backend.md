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

O workflow de apply verifica os dois recursos antes de executar terraform init.
Ele nao tenta cria-los, evitando que o Terraform dependa de um backend que ainda
nao existe.

## Operacao

- CI — Terraform: valida em todo push/PR e executa plan real em PR quando
  AWS_CREDENTIALS_READY=true;
- Terraform — Apply EKS: manual, exige APLICAR-PROD e aprovacao do Environment;
- Terraform — Destroy EKS: manual, exige DESTRUIR-PROD, remove load balancers
  externos ao state e preserva bucket, tabela e state.

As tres operacoes usam o mesmo grupo de concorrencia para impedir alteracoes
simultaneas no state.

## Recuperacao

Se uma execucao for interrompida, nao apague bucket, tabela ou lock manualmente.
Primeiro confirme que nao ha outro workflow em andamento. Depois execute
terraform plan para reconciliar state e AWS. Use uma versao anterior do objeto
S3 somente quando houver evidencia de corrupcao do state.
