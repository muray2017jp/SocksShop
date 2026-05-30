#!/bin/bash

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
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} 2>/dev/null && echo "kubeconfig更新完了" || echo "クラスターが存在しないためスキップ"

# ===================================================
# PHASE 2: Ingress削除 → ALB削除待ち → SocksShop削除
# ===================================================
echo "=== [Phase2] Ingress削除 (ALBを先に削除) ==="
kubectl delete ingress sockshop -n sock-shop 2>/dev/null && echo "Ingress削除完了" || echo "Ingressスキップ"

echo "=== [Phase2] ALB削除待ち（最大5分）==="
for i in $(seq 1 30); do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region ${REGION}     --query "LoadBalancers[?contains(LoadBalancerName,'k8s-sockshop')].LoadBalancerName"     --output text 2>/dev/null | wc -w)
  if [ "${ALB_COUNT}" -eq "0" ]; then
    echo "ALB削除確認完了"
    break
  fi
  echo "  ALB削除待ち... (${i}/30)"
  sleep 10
done

echo "=== [Phase2] SocksShopアプリ削除 ==="
kubectl delete -f "https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml" 2>/dev/null && echo "SocksShop削除完了" || echo "SocksShopスキップ"
kubectl delete namespace sockshop 2>/dev/null && echo "sockshop namespace削除完了" || echo "sockshop namespaceスキップ"

# ===================================================
# PHASE 3: Route53レコード削除
# ===================================================
echo "=== [Phase3] Route53レコード削除 ==="
cd ${TF_ROUTE53_DIR}
terraform init -input=false 2>/dev/null || true
terraform destroy -auto-approve 2>/dev/null && echo "Route53レコード削除完了" || echo "Route53レコードスキップ"

# ===================================================
# PHASE 4: Terraform destroy
# ===================================================
echo "=== [Phase4] kubeconfig再更新 (Helmプロバイダー用) ==="
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} 2>/dev/null && echo "kubeconfig更新完了" || echo "クラスターが存在しないためスキップ"

echo "=== [Phase4] Terraform destroy ==="
cd ${TF_DIR}
terraform destroy -auto-approve || true

# ===================================================
# PHASE 5: IAM・KMS・CloudWatch・tfstate削除
# ===================================================
echo "=== [Phase5] IAM User削除 ==="
for USER in admin_user develop_user; do
  for KEY_ID in $(aws iam list-access-keys --user-name $USER --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null); do
    aws iam delete-access-key --user-name $USER --access-key-id $KEY_ID 2>/dev/null || true
  done
  for GROUP in $(aws iam list-groups-for-user --user-name $USER --query "Groups[].GroupName" --output text 2>/dev/null); do
    aws iam remove-user-from-group --group-name $GROUP --user-name $USER 2>/dev/null || true
  done
  aws iam delete-user --user-name $USER 2>/dev/null && echo "$USER 削除完了" || echo "$USER スキップ"
done

echo "=== [Phase5] IAM Group削除 ==="
for GROUP in admin develop; do
  for ARN in $(aws iam list-attached-group-policies --group-name $GROUP --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-group-policy --group-name $GROUP --policy-arn $ARN 2>/dev/null || true
  done
  for PNAME in $(aws iam list-group-policies --group-name $GROUP --query "PolicyNames" --output text 2>/dev/null); do
    aws iam delete-group-policy --group-name $GROUP --policy-name $PNAME 2>/dev/null || true
  done
  aws iam delete-group --group-name $GROUP 2>/dev/null && echo "$GROUP 削除完了" || echo "$GROUP スキップ"
done

echo "=== [Phase5] IAM Role削除 ==="
for ROLE in eks-alb-controller eks-admin-role eks-develop-role; do
  for ARN in $(aws iam list-attached-role-policies --role-name $ROLE --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $ARN 2>/dev/null || true
  done
  for PNAME in $(aws iam list-role-policies --role-name $ROLE --query "PolicyNames" --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name $ROLE --policy-name $PNAME 2>/dev/null || true
  done
  aws iam delete-role --role-name $ROLE 2>/dev/null && echo "$ROLE 削除完了" || echo "$ROLE スキップ"
done

echo "=== [Phase5] IAM Policy削除 ==="
ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query "PolicyRoles[].RoleName" --output text 2>/dev/null || true)
for ROLE in $ATTACHED_ROLES; do
  aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN 2>/dev/null || true
done
aws iam delete-policy --policy-arn $POLICY_ARN 2>/dev/null && echo "IAM Policy削除完了" || echo "IAM Policy スキップ"

echo "=== [Phase5] EKS Access Entry削除 ==="
for PRINCIPAL in "arn:aws:iam::${ACCOUNT_ID}:user/terraform" "arn:aws:iam::${ACCOUNT_ID}:user/cicd"; do
  aws eks delete-access-entry --cluster-name $CLUSTER_NAME     --principal-arn $PRINCIPAL     --region $REGION 2>/dev/null && echo "Access Entry削除完了: $PRINCIPAL" || echo "Access Entry スキップ: $PRINCIPAL"
done

echo "=== [Phase5] KMS・CloudWatch・tfstate削除 ==="
aws kms delete-alias --alias-name $KMS_ALIAS --region $REGION 2>/dev/null && echo "KMS Alias削除完了" || echo "KMS Alias スキップ"

KEY_ID=$(aws kms list-aliases --region $REGION   --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId"   --output text 2>/dev/null || true)
if [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ]; then
  aws kms schedule-key-deletion --key-id $KEY_ID --pending-window-in-days 7 --region $REGION 2>/dev/null     && echo "KMS Key削除スケジュール完了" || echo "KMS Key スキップ"
fi

aws logs delete-log-group --log-group-name /aws/eks/${CLUSTER_NAME}/cluster   --region $REGION 2>/dev/null && echo "CloudWatch Log Group削除完了" || echo "CloudWatch Log Group スキップ"

rm -f ${TF_DIR}/terraform.tfstate
rm -f ${TF_DIR}/terraform.tfstate.backup
rm -f ${TF_ROUTE53_DIR}/terraform.tfstate
rm -f ${TF_ROUTE53_DIR}/terraform.tfstate.backup
echo "tfstate削除完了"

echo ""
echo "=== 完了 ==="
echo "すべてのリソースを削除しました。次回 apply.sh を実行できます。"
echo "※ KMS Key は AWS の仕様により 7 日後に完全削除されます。"
