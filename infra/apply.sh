#!/bin/bash

set -e

REGION="ap-northeast-1"
CLUSTER_NAME="eks-example"
POLICY_ARN="arn:aws:iam::455110051621:policy/AWSLoadBalancerControllerIAMPolicy"
TF_DIR=~/SocksShop/infra/terraform/envs/production
TF_ROUTE53_DIR=~/SocksShop/infra/terraform/envs/route53

cd ${TF_DIR}

# ===================================================
# PHASE 1: Terraform (EKS・VPC・IAM・Helm)
# ===================================================
if [ -f terraform.tfstate ] && [ -s terraform.tfstate ]; then
  echo "=== [Phase1] tfstate が存在します。既存リソースを維持して差分のみ適用します ==="
else
  echo "=== [Phase1] tfstate が存在しません。フルセットアップを開始します ==="

  echo "Delete old EKS OIDC Providers"
  OIDC_LIST=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text)
  for OIDC_ARN in ${OIDC_LIST}; do
    if [[ "${OIDC_ARN}" == *"oidc.eks.${REGION}.amazonaws.com"* ]]; then
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn ${OIDC_ARN}
    fi
  done

  echo "Delete old ALB Controller IAM Policy"
  aws iam delete-policy --policy-arn ${POLICY_ARN} 2>/dev/null || true

  echo "Terraform state cleanup"
  rm -f terraform.tfstate
  rm -f terraform.tfstate.backup
fi

echo "=== [Phase1] Terraform init & apply ==="
terraform init
terraform apply -auto-approve

# ===================================================
# PHASE 2: kubeconfig更新
# ===================================================
echo "=== [Phase2] kubeconfig更新 ==="
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}

# ===================================================
# PHASE 3: SocksShopアプリデプロイ
# ===================================================
echo "=== [Phase3] SocksShopアプリデプロイ ==="

kubectl get namespace sock-shop 2>/dev/null || kubectl create namespace sock-shop

kubectl apply -f "https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml"

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sockshop
  namespace: sock-shop
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-1:455110051621:certificate/d7ec3e28-53c4-446d-9ae5-a8d09e8b41c1
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
    - host: sockshop.jyouhou.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: front-end
                port:
                  number: 80
EOF

# ===================================================
# PHASE 4: Pod全起動待ち（最大5分）
# ===================================================
echo "=== [Phase4] Pod全起動待ち（最大5分）==="
for i in $(seq 1 30); do
  PENDING=$(kubectl get pods -n sock-shop --no-headers 2>/dev/null | grep -c "Pending" || true)
  echo "  待機中... Pending:${PENDING} (${i}/30)"
  if [ "${PENDING}" -eq "0" ]; then
    echo "全Pod起動確認完了"
    break
  fi
  sleep 10
done

# ===================================================
# PHASE 5: ALB作成待ち（最大10分）
# ===================================================
echo "=== [Phase5] ALB作成待ち（最大10分）==="
for i in $(seq 1 60); do
  ALB_COUNT=$(aws elbv2 describe-load-balancers --region ${REGION}     --query "LoadBalancers[?contains(LoadBalancerName,'k8s-sockshop')].LoadBalancerName"     --output text 2>/dev/null | wc -w)
  if [ "${ALB_COUNT}" -gt "0" ]; then
    echo "ALB作成確認完了"
    break
  fi
  echo "  ALB作成待ち... (${i}/60)"
  sleep 10
done

# ===================================================
# PHASE 6: Route53登録（別ディレクトリで管理）
# ===================================================
echo "=== [Phase6] Route53登録 ==="
cd ${TF_ROUTE53_DIR}
terraform init
terraform apply -auto-approve

echo ""
echo "=== 完了 ==="
echo "アクセスURL: https://sockshop.jyouhou.net"
echo ""
echo "Pod起動状況:"
kubectl get pods -n sock-shop
