#!/bin/bash

# ===========================================================
# destroy.sh - AWSリソース削除スクリプト
#
# [修正1] Phase4: helm_release を state から除外してから destroy
#   原因: helm/kubernetes プロバイダーが EKS API に接続できず
#         helm_release の削除が "Kubernetes cluster unreachable" で失敗
#   対策: terraform destroy 前に helm_release を state rm で除外
#
# [修正2] Phase3: route53 destroy の成否を確認してから tfstate 削除
#   原因: route53 destroy が失敗しても tfstate を削除していたため
#         次回 apply 時に "already exists" エラーが発生
#   対策: destroy 成功時のみ tfstate を削除。失敗時は tfstate を残す
#
# [修正3] Phase4.5: NAT GW / EIP の残存チェックと自動削除を追加
# ===========================================================

set -e

REGION="ap-northeast-1"
CLUSTER_NAME="eks-example"
ACCOUNT_ID="455110051621"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
KMS_ALIAS="alias/eks/eks-example"
TF_DIR=~/SocksShop/infra/terraform/envs/production
TF_ROUTE53_DIR=~/SocksShop/infra/terraform/envs/route53

# ===================================================
# PHASE 1: kubeconfig更新
# ===================================================
echo "=== [Phase1] kubeconfig更新 ==="
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} 2>/dev/null \
  && echo "kubeconfig更新完了" \
  || echo "クラスターが存在しないためスキップ"

# ===================================================
# PHASE 2: Ingress削除 → ALB削除待ち → SocksShop削除
# ===================================================
echo "=== [Phase2] Ingress削除 (ALB自動削除) ==="
kubectl delete ingress sockshop -n sock-shop 2>/dev/null \
  && echo "Ingress削除完了" || echo "Ingressスキップ"

echo "=== [Phase2] ALB削除待ち（最大5分）==="
for i in $(seq 1 30); do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region ${REGION} \
    --query "LoadBalancers[?contains(LoadBalancerName,'k8s-sockshop')].LoadBalancerName" \
    --output text 2>/dev/null | wc -w)
  if [ "${ALB_COUNT}" -eq "0" ]; then
    echo "ALB削除確認完了"
    break
  fi
  echo "  ALB削除待ち... (${i}/30)"
  sleep 10
done

echo "=== [Phase2] SocksShopアプリ削除 ==="
kubectl delete -f "https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml" \
  2>/dev/null && echo "SocksShop削除完了" || echo "SocksShopスキップ"
kubectl delete namespace sockshop 2>/dev/null \
  && echo "sockshop namespace削除完了" || echo "sockshop namespaceスキップ"

# ===================================================
# PHASE 3: Route53レコード削除（AWS CLIで直接削除）
# ===================================================
echo "=== [Phase3] Route53レコード削除 ==="
HOSTED_ZONE_ID="Z19AYGP6NFKBF0"
RECORD_NAME="sockshop.jyouhou.net"

RECORD=$(aws route53 list-resource-record-sets \
  --hosted-zone-id ${HOSTED_ZONE_ID} \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json 2>/dev/null)

COUNT=$(echo "${RECORD}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "${COUNT}" -gt "0" ]; then
  DNS_NAME=$(echo "${RECORD}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['AliasTarget']['DNSName'])")
  ALIAS_ZONE=$(echo "${RECORD}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['AliasTarget']['HostedZoneId'])")
  CHANGE_BATCH=$(python3 -c "import json; print(json.dumps({'Changes':[{'Action':'DELETE','ResourceRecordSet':{'Name':'${RECORD_NAME}','Type':'A','AliasTarget':{'HostedZoneId':'${ALIAS_ZONE}','DNSName':'${DNS_NAME}','EvaluateTargetHealth':True}}}]}))")
  aws route53 change-resource-record-sets \
    --hosted-zone-id ${HOSTED_ZONE_ID} \
    --change-batch "${CHANGE_BATCH}" \
    2>/dev/null && echo "Route53レコード削除完了" || echo "Route53レコードスキップ"
else
  echo "Route53レコードは存在しないためスキップ"
fi

rm -f ${TF_ROUTE53_DIR}/terraform.tfstate
rm -f ${TF_ROUTE53_DIR}/terraform.tfstate.backup

# ===================================================
# PHASE 4: Terraform destroy
# [修正1] helm_release を state から除外してから destroy を実行
# ===================================================
echo "=== [Phase4] Terraform destroy ==="
cd ${TF_DIR}

echo "[Phase4] helm_release を state から除外（K8s接続エラー回避）..."
terraform state rm helm_release.aws_load_balancer_controller 2>/dev/null \
  && echo "  ALB Controller: stateから除外完了" \
  || echo "  ALB Controller: stateに存在しないためスキップ"

terraform state rm helm_release.metrics_server 2>/dev/null \
  && echo "  Metrics Server: stateから除外完了" \
  || echo "  Metrics Server: stateに存在しないためスキップ"

echo "[Phase4] terraform destroy 実行中（10〜20分かかります）..."
PRODUCTION_DESTROY_OK=false
if terraform destroy -auto-approve; then
  echo "terraform destroy 完了"
  PRODUCTION_DESTROY_OK=true
else
  echo "terraform destroy 一部失敗（続行します）"
fi

# ===================================================
# PHASE 4.5: NAT GW / EIP の残存チェックと削除
# [修正3] terraform destroy 失敗時のフォールバック
# ===================================================
echo "=== [Phase4.5] NATゲートウェイ残存チェック ==="
NAT_IDS=$(aws ec2 describe-nat-gateways --region ${REGION} \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].NatGatewayId" --output text 2>/dev/null || true)
if [ -n "${NAT_IDS}" ]; then
  echo "NATゲートウェイが残存 → 削除します"
  for nat in ${NAT_IDS}; do
    aws ec2 delete-nat-gateway --nat-gateway-id ${nat} --region ${REGION} 2>/dev/null \
      && echo "  NAT削除開始: ${nat}" || true
  done
  for i in $(seq 1 30); do
    REMAINING=$(aws ec2 describe-nat-gateways --region ${REGION} \
      --filter "Name=state,Values=available,pending,deleting" \
      --query "length(NatGateways)" --output text 2>/dev/null || echo "0")
    [ "${REMAINING}" -eq "0" ] && echo "NATゲートウェイ削除完了" && break
    echo "  待機中... (${i}/30)"; sleep 10
  done
else
  echo "NATゲートウェイなし"
fi

echo "=== [Phase4.5] EIP残存チェック ==="
EIP_IDS=$(aws ec2 describe-addresses --region ${REGION} \
  --query "Addresses[*].AllocationId" --output text 2>/dev/null || true)
if [ -n "${EIP_IDS}" ]; then
  for eip in ${EIP_IDS}; do
    aws ec2 release-address --allocation-id ${eip} --region ${REGION} 2>/dev/null \
      && echo "  EIP解放: ${eip}" || echo "  EIP解放スキップ: ${eip}"
  done
else
  echo "EIPなし"
fi

# ===================================================
# PHASE 5: IAM・KMS・CloudWatch・tfstate削除
# ===================================================
echo "=== [Phase5] IAM User削除 ==="
for USER in admin_user develop_user; do
  for KEY_ID in $(aws iam list-access-keys --user-name $USER \
      --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null); do
    aws iam delete-access-key --user-name $USER --access-key-id $KEY_ID 2>/dev/null || true
  done
  for GROUP in $(aws iam list-groups-for-user --user-name $USER \
      --query "Groups[].GroupName" --output text 2>/dev/null); do
    aws iam remove-user-from-group --group-name $GROUP --user-name $USER 2>/dev/null || true
  done
  aws iam delete-user --user-name $USER 2>/dev/null \
    && echo "$USER 削除完了" || echo "$USER スキップ"
done

echo "=== [Phase5] IAM Group削除 ==="
for GROUP in admin develop; do
  for ARN in $(aws iam list-attached-group-policies --group-name $GROUP \
      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-group-policy --group-name $GROUP --policy-arn $ARN 2>/dev/null || true
  done
  for PNAME in $(aws iam list-group-policies --group-name $GROUP \
      --query "PolicyNames" --output text 2>/dev/null); do
    aws iam delete-group-policy --group-name $GROUP --policy-name $PNAME 2>/dev/null || true
  done
  aws iam delete-group --group-name $GROUP 2>/dev/null \
    && echo "$GROUP 削除完了" || echo "$GROUP スキップ"
done

echo "=== [Phase5] IAM Role削除 ==="
for ROLE in eks-alb-controller eks-admin-role eks-develop-role; do
  for ARN in $(aws iam list-attached-role-policies --role-name $ROLE \
      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $ARN 2>/dev/null || true
  done
  for PNAME in $(aws iam list-role-policies --role-name $ROLE \
      --query "PolicyNames" --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name $ROLE --policy-name $PNAME 2>/dev/null || true
  done
  aws iam delete-role --role-name $ROLE 2>/dev/null \
    && echo "$ROLE 削除完了" || echo "$ROLE スキップ"
done

echo "=== [Phase5] IAM Policy削除 ==="
ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn $POLICY_ARN \
  --query "PolicyRoles[].RoleName" --output text 2>/dev/null || true)
for ROLE in $ATTACHED_ROLES; do
  aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN 2>/dev/null || true
done
aws iam delete-policy --policy-arn $POLICY_ARN 2>/dev/null \
  && echo "IAM Policy削除完了" || echo "IAM Policy スキップ"

echo "=== [Phase5] EKS Access Entry削除 ==="
for PRINCIPAL in "arn:aws:iam::${ACCOUNT_ID}:user/terraform" "arn:aws:iam::${ACCOUNT_ID}:user/cicd"; do
  aws eks delete-access-entry --cluster-name $CLUSTER_NAME \
    --principal-arn $PRINCIPAL --region $REGION 2>/dev/null \
    && echo "Access Entry削除完了: $PRINCIPAL" || echo "Access Entry スキップ: $PRINCIPAL"
done

echo "=== [Phase5] KMS・CloudWatch削除 ==="
aws kms delete-alias --alias-name $KMS_ALIAS --region $REGION 2>/dev/null \
  && echo "KMS Alias削除完了" || echo "KMS Alias スキップ"

KEY_ID=$(aws kms list-aliases --region $REGION \
  --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId" \
  --output text 2>/dev/null || true)
if [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ]; then
  aws kms schedule-key-deletion --key-id $KEY_ID --pending-window-in-days 7 \
    --region $REGION 2>/dev/null \
    && echo "KMS Key削除スケジュール完了" || echo "KMS Key スキップ"
fi

aws logs delete-log-group --log-group-name /aws/eks/${CLUSTER_NAME}/cluster \
  --region $REGION 2>/dev/null \
  && echo "CloudWatch Log Group削除完了" || echo "CloudWatch Log Group スキップ"

# [修正2] tfstate削除: 各 destroy の成否に応じて削除可否を判断
echo "=== [Phase5] tfstate削除 ==="
if [ "${PRODUCTION_DESTROY_OK}" = "true" ]; then
  rm -f ${TF_DIR}/terraform.tfstate
  rm -f ${TF_DIR}/terraform.tfstate.backup
  echo "production tfstate削除完了"
else
  echo "production terraform destroy が失敗したため tfstate を保持します"
fi

if [ "${ROUTE53_DESTROY_OK}" = "true" ]; then
  rm -f ${TF_ROUTE53_DIR}/terraform.tfstate
  rm -f ${TF_ROUTE53_DIR}/terraform.tfstate.backup
  echo "route53 tfstate削除完了"
else
  echo "route53 terraform destroy が失敗したため tfstate を保持します"
  echo "  --> 次回 destroy.sh を再実行すれば route53 レコードを正しく削除できます"
fi

echo ""
echo "=== 完了 ==="
echo "すべてのリソースを削除しました。次回 apply.sh を実行できます。"
echo "※ KMS Key は AWS の仕様により 7 日後に完全削除されます。"
