# Retomada dos serviços de nós no AWS Academy

Em 15/11 o grupo default estava ACTIVE, duas EC2 InService/Healthy e nenhuma
registrada em Kubernetes. O usuário confirmou kubelet inactive (dead), disabled
em uma instância. O provisionamento e os rollouts haviam passado antes da parada
do lab; o apply posterior não encontrou diferença no node group.

Terraform reconcilia recursos AWS, não o estado dos daemons dentro das EC2.
Nas AMIs AL2023 do EKS, nodeadm-config e nodeadm-run configuram e iniciam kubelet.
Disabled, isoladamente, não prova defeito: kubelet é iniciado pelo nodeadm.
O motivo da interrupção deve ser conferido nos estados/journal dessas unidades.

O workflow `EKS node services - Academy` usa os três Organization secrets AWS e
o Environment prod existente. Não requer novos secrets, IAM, SSH ou conexão manual.

- `inspect`: consulta unidades, presença de arquivos e erros sanitizados via SSM.
- `resume`: faz a mesma coleta e, apenas se kubelet não está ativo, inicia na ordem
  as unidades originais nodeadm-config/nodeadm-run. Não altera enable/disable,
  AMI, launch template, credenciais, policies, dados ou volumes.

Os alvos são descobertos exclusivamente no ASG do node group default. O script
confere VPC, instâncias em execução, NodeConfig gerenciado com cluster/endpoint
esperados e SSM Online. No modo resume a confirmação é
`RETOMAR SERVICOS DOS NOS`; após iniciar, exige registro/Ready dos nós e rollouts.

Falhas são reportadas sem imprimir configurações, tokens, Secrets ou journal bruto.
O workflow não adiciona permissões caso o Academy negue SSM.

Referência: https://docs.aws.amazon.com/eks/latest/userguide/al2023.html
