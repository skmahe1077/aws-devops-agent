#!/bin/bash
# RDS Security Group Rollback Script
# Restores ingress rules allowing EKS to connect to RDS instances

set -e

REGION="${AWS_REGION:-us-east-1}"

echo "=== RDS Security Group Rollback ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$SCRIPT_DIR/rds-sg-ids.json"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: No backup file found at $BACKUP_FILE"
  echo "Cannot rollback without knowing which rules were revoked."
  echo ""
  echo "Manual rollback: Add ingress rules to your RDS security groups allowing"
  echo "traffic from your EKS cluster security group on ports 3306 and/or 5432."
  exit 1
fi

REGION=$(jq -r '.region' "$BACKUP_FILE")
EKS_SG=$(jq -r '.eks_sg' "$BACKUP_FILE")
REVOKED_RULES=$(jq -r '.revoked_rules' "$BACKUP_FILE")

echo "Region: $REGION"
echo "EKS Security Group: $EKS_SG"
echo ""

RULE_COUNT=$(echo "$REVOKED_RULES" | jq 'length')
if [ "$RULE_COUNT" -eq 0 ]; then
  echo "No rules to restore."
  exit 0
fi

echo "[1/4] Restoring $RULE_COUNT security group rules..."
echo ""

RESTORED=0
FAILED=0

for row in $(echo "$REVOKED_RULES" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  RDS_SG=$(_jq '.rds_sg')
  EKS_SG=$(_jq '.eks_sg')
  PORT=$(_jq '.port')
  DB_ID=$(_jq '.db_id')

  echo "  Restoring: $DB_ID (SG: $RDS_SG, Port: $PORT)"

  if AWS_PAGER="" aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG \
    --protocol tcp \
    --port $PORT \
    --source-group $EKS_SG \
    --region $REGION 2>/dev/null; then
    echo "    Port $PORT rule restored"
    RESTORED=$((RESTORED + 1))
  else
    echo "    Failed to restore port $PORT (may already exist)"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "  Restored: $RESTORED rules | Failed: $FAILED rules"

# Restart pods to reconnect
echo ""
echo "[2/4] Restarting application pods..."

if kubectl get deployment -n orders orders &>/dev/null; then
  kubectl rollout restart deployment -n orders orders 2>/dev/null && echo "  Restarted orders deployment"
fi

if kubectl get deployment -n catalog catalog &>/dev/null; then
  kubectl rollout restart deployment -n catalog catalog 2>/dev/null && echo "  Restarted catalog deployment"
fi

echo ""
echo "Waiting 45 seconds for pods to restart..."
sleep 45

# Check pod status
echo ""
echo "[3/4] Checking pod status..."
echo ""
echo "  Orders pods:"
kubectl get pods -n orders -l app.kubernetes.io/name=orders --no-headers 2>/dev/null | sed 's/^/    /'
echo ""
echo "  Catalog pods:"
kubectl get pods -n catalog -l app.kubernetes.io/name=catalog --no-headers 2>/dev/null | sed 's/^/    /'

# Check connectivity
echo ""
echo "[4/4] Checking service connectivity..."

check_service() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4

  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2

  if kill -0 $pf_pid 2>/dev/null; then
    local status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$local_port$endpoint" 2>/dev/null)
    kill $pf_pid 2>/dev/null
    if [ "$status" == "200" ] || [ "$status" == "201" ]; then
      echo "  $service: HTTP $status (healthy)"
    else
      echo "  $service: HTTP $status"
    fi
  else
    echo "  $service: Could not connect"
  fi
}

check_service "orders" "orders" 8080 "/orders"
check_service "catalog" "catalog" 8082 "/catalogue"

echo ""
echo "=== Rollback Complete ==="
