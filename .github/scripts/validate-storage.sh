#!/usr/bin/env bash
# Prova real de provisionamento EBS. Somente o namespace temporario desta execucao
# e removido; volumes/PVCs de aplicacoes nao sao alterados.
set -Eeuo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME ausente}"
: "${STORAGE_CLASS:?STORAGE_CLASS ausente}"
: "${AWS_REGION:?AWS_REGION ausente}"

namespace="soat-storage-check-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}"
created=false
volume_id=''
error_file="$(mktemp)"

cleanup() {
  status=$?
  trap - EXIT
  if [ "$created" = true ]; then
    pv="$(kubectl -n "$namespace" get pvc probe -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    if [ -n "$pv" ]; then
      volume_id="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)"
    fi
    if [ "$status" != '0' ]; then
      kubectl -n "$namespace" get pods,pvc -o wide || true
      kubectl -n "$namespace" get events --sort-by=.lastTimestamp || true
    fi
    if ! kubectl delete namespace "$namespace" --wait=true --timeout=180s; then
      echo "::error::Limpeza pendente do namespace temporario $namespace."
      status=1
    fi
    if [[ "$volume_id" =~ ^vol-[a-f0-9]+$ ]]; then
      deleted=false
      for attempt in {1..36}; do
        if aws ec2 describe-volumes --volume-ids "$volume_id" --region "$AWS_REGION" >/dev/null 2>"$error_file"; then
          sleep 5
        elif grep -q 'InvalidVolume.NotFound' "$error_file"; then
          deleted=true
          break
        else
          echo "::error::Nao foi possivel confirmar a remocao do volume temporario $volume_id."
          break
        fi
      done
      if [ "$deleted" != true ]; then
        echo "::error::Limpeza do volume temporario $volume_id nao comprovada. Conferir antes de repetir."
        status=1
      fi
    elif [ -n "$pv" ]; then
      echo "::error::Volume temporario vinculado, mas identificador EBS nao foi obtido para conferir limpeza."
      status=1
    fi
  fi
  rm -f "$error_file"
  exit "$status"
}
trap cleanup EXIT

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
test "$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" --query addon.status --output text)" = 'ACTIVE'
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=180s
kubectl -n kube-system rollout status daemonset/ebs-csi-node --timeout=180s
kubectl get csidriver ebs.csi.aws.com
kubectl get storageclass "$STORAGE_CLASS" -o json | jq -e '
  .provisioner == "ebs.csi.aws.com" and
  .parameters.type == "gp3" and
  .parameters.encrypted == "true" and
  .volumeBindingMode == "WaitForFirstConsumer" and
  .reclaimPolicy == "Delete"' >/dev/null

# create falha se o namespace ja existir: nunca adotar/apagar recursos de outra execucao.
kubectl create namespace "$namespace"
created=true
kubectl -n "$namespace" apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: probe
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: "$STORAGE_CLASS"
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 120
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox:1.37.0
      command: [sh, -ec, "echo soat-storage-ok > /data/probe && grep -qx soat-storage-ok /data/probe"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: probe
YAML

# O Pod ja existe antes da espera: WaitForFirstConsumer precisa dele para escolher a AZ.
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Bound pvc/probe --timeout=180s
pv="$(kubectl -n "$namespace" get pvc probe -o jsonpath='{.spec.volumeName}')"
volume_id="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ "$volume_id" =~ ^vol-[a-f0-9]+$ ]]
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=180s
aws ec2 describe-volumes --volume-ids "$volume_id" --region "$AWS_REGION" --output json |
  jq -e '.Volumes | length == 1 and all(.[]; .Encrypted == true and .VolumeType == "gp3")' >/dev/null
echo 'EBS CSI: volume gp3 criptografado provisionado; escrita/leitura aprovadas. Limpando prova temporaria.'
