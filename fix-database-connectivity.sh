#!/bin/bash
# Single-click script to fix database connectivity
# Adds EKS node security group rules to RDS security groups

set -e

REGION="${AWS_REGION:-us-east-1}"
TERRAFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/terraform" && pwd)"

echo "=== Fix Database Connectivity ==="
echo ""

# Get security group IDs from Terraform output
echo "[1/4] Reading Terraform outputs..."
cd "$TERRAFORM_DIR"

EKS_NODE_SG=$(terraform output -raw eks_node_security_group_id 2>/dev/null)
CATALOG_SG=$(terraform output -raw catalog_rds_security_group_id 2>/dev/null)
ORDERS_SG=$(terraform output -raw orders_rds_security_group_id 2>/dev/null)

echo "  EKS Node SG:    $EKS_NODE_SG"
echo "  Catalog RDS SG: $CATALOG_SG"
echo "  Orders RDS SG:  $ORDERS_SG"
echo ""

# Add EKS node SG to catalog RDS (MySQL 3306)
echo "[2/4] Adding EKS access to Catalog RDS (MySQL 3306)..."
if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
  --group-id $CATALOG_SG \
  --protocol tcp \
  --port 3306 \
  --source-group $EKS_NODE_SG \
  --region $REGION 2>/dev/null; then
  echo "  Rule added successfully"
else
  echo "  Rule already exists (skipping)"
fi

# Add EKS node SG to orders RDS (PostgreSQL 5432)
echo ""
echo "[3/4] Adding EKS access to Orders RDS (PostgreSQL 5432)..."
if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
  --group-id $ORDERS_SG \
  --protocol tcp \
  --port 5432 \
  --source-group $EKS_NODE_SG \
  --region $REGION 2>/dev/null; then
  echo "  Rule added successfully"
else
  echo "  Rule already exists (skipping)"
fi

# Restart pods
echo ""
echo "[4/4] Restarting application pods..."
kubectl rollout restart deployment -n catalog catalog 2>/dev/null && echo "  Restarted catalog"
kubectl rollout restart deployment -n orders orders 2>/dev/null && echo "  Restarted orders"

echo ""
echo "Waiting 45 seconds for pods to be ready..."
sleep 45

# Verify
echo ""
echo "=== Pod Status ==="
echo ""
echo "Catalog:"
kubectl get pods -n catalog -l app.kubernetes.io/name=catalog --no-headers 2>/dev/null | sed 's/^/  /'
echo ""
echo "Orders:"
kubectl get pods -n orders -l app.kubernetes.io/name=orders --no-headers 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== Fix Complete ==="
echo ""
echo "Refresh the website to verify products and orders are working."
echo ""
echo "To break it again for demo:  ./fault-injection/inject-rds-sg-block.sh"
echo "To fix it again:             ./fault-injection/rollback-rds-sg-block.sh"
