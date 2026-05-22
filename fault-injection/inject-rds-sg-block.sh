#!/bin/bash
# RDS Security Group Misconfiguration Injection
# Removes ingress rules allowing EKS to connect to ALL RDS instances
# Blocks both MySQL (3306) and PostgreSQL (5432) ports

set -e

REGION="${AWS_REGION:-us-east-1}"

echo "=== RDS Security Group Misconfiguration Injection ==="
echo ""
echo "Region: $REGION"
echo ""

# Auto-discover EKS cluster
echo "[1/5] Discovering EKS cluster..."
EKS_CLUSTER=$(AWS_PAGER="" aws eks list-clusters --region $REGION --query "clusters[0]" --output text 2>/dev/null)

if [ -z "$EKS_CLUSTER" ] || [ "$EKS_CLUSTER" == "None" ]; then
  echo "ERROR: No EKS cluster found in region $REGION"
  exit 1
fi

echo "  EKS Cluster: $EKS_CLUSTER"
echo ""

# Auto-discover all RDS instances and their security groups
echo "[2/5] Discovering RDS instances and security groups..."
RDS_INFO=$(AWS_PAGER="" aws rds describe-db-instances --region $REGION \
  --query "DBInstances[*].[DBInstanceIdentifier,VpcSecurityGroups[0].VpcSecurityGroupId,Endpoint.Port]" \
  --output json 2>/dev/null)

if [ -z "$RDS_INFO" ] || [ "$RDS_INFO" == "[]" ]; then
  echo "ERROR: No RDS instances found in region $REGION"
  exit 1
fi

echo "  Found RDS instances:"
echo "$RDS_INFO" | jq -r '.[] | "    - \(.[0]) (SG: \(.[1]), Port: \(.[2]))"'
echo ""

# Find all EKS-related source SGs in RDS security group ingress rules
echo "[3/5] Scanning RDS security group ingress rules for EKS source SGs..."
REVOKED_RULES="[]"

for row in $(echo "$RDS_INFO" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  DB_ID=$(_jq '.[0]')
  RDS_SG=$(_jq '.[1]')
  DB_PORT=$(_jq '.[2]')

  echo "  Processing: $DB_ID (SG: $RDS_SG, Port: $DB_PORT)"

  # Get all ingress rules with source security groups (exclude self-referencing)
  SOURCE_SGS=$(AWS_PAGER="" aws ec2 describe-security-groups --group-ids $RDS_SG --region $REGION \
    --query "SecurityGroups[0].IpPermissions[*].{Port:FromPort,Sources:UserIdGroupPairs[*].GroupId}" \
    --output json 2>/dev/null)

  # Find and revoke each non-self source SG rule
  for rule_row in $(echo "$SOURCE_SGS" | jq -r '.[] | @base64'); do
    RULE_PORT=$(echo ${rule_row} | base64 --decode | jq -r '.Port')
    SOURCES=$(echo ${rule_row} | base64 --decode | jq -r '.Sources[]? // empty')

    for SOURCE_SG in $SOURCES; do
      # Skip self-referencing rules
      if [ "$SOURCE_SG" == "$RDS_SG" ]; then
        continue
      fi

      # This is an EKS/external SG allowing access - revoke it
      if AWS_PAGER="" aws ec2 revoke-security-group-ingress \
        --group-id $RDS_SG \
        --protocol tcp \
        --port $RULE_PORT \
        --source-group $SOURCE_SG \
        --region $REGION 2>/dev/null; then
        echo "    Revoked port $RULE_PORT from $SOURCE_SG"
        REVOKED_RULES=$(echo "$REVOKED_RULES" | jq ". + [{\"rds_sg\": \"$RDS_SG\", \"eks_sg\": \"$SOURCE_SG\", \"port\": $RULE_PORT, \"db_id\": \"$DB_ID\"}]")
      fi
    done
  done
done

# Save revoked rules for rollback
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "{\"region\": \"$REGION\", \"revoked_rules\": $REVOKED_RULES}" > "$SCRIPT_DIR/rds-sg-ids.json"
echo ""
echo "  Backup saved to: $SCRIPT_DIR/rds-sg-ids.json"

REVOKED_COUNT=$(echo "$REVOKED_RULES" | jq 'length')
if [ "$REVOKED_COUNT" -eq 0 ]; then
  echo ""
  echo "WARNING: No rules were revoked. Security groups may not have matching rules."
  echo "The bug may already be active (no EKS SG rules found on RDS)."
  exit 0
fi

echo ""
echo "=== Security Group Misconfiguration Injection Complete ==="
echo ""
echo "Revoked $REVOKED_COUNT security group rules"
echo ""

# Step 4: Restart pods to trigger connection errors
echo "[4/5] Restarting application pods to trigger connection errors..."

if kubectl get deployment -n orders orders &>/dev/null; then
  kubectl rollout restart deployment -n orders orders 2>/dev/null && echo "  Restarted orders deployment"
fi

if kubectl get deployment -n catalog catalog &>/dev/null; then
  kubectl rollout restart deployment -n catalog catalog 2>/dev/null && echo "  Restarted catalog deployment"
fi

echo ""
echo "Waiting 30 seconds for pods to restart and fail..."
sleep 30

# Step 5: Generate traffic to trigger errors
echo ""
echo "[5/5] Generating traffic to trigger database connection errors..."

generate_traffic() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4

  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2

  if kill -0 $pf_pid 2>/dev/null; then
    echo "  Sending requests to $service..."
    for i in {1..10}; do
      curl -s -o /dev/null -w "%{http_code} " "http://localhost:$local_port$endpoint" 2>/dev/null
    done
    echo ""
    kill $pf_pid 2>/dev/null
    echo "  $service: 10 requests sent"
  else
    echo "  - Could not port-forward to $service"
  fi
}

generate_traffic "orders" "orders" 8080 "/orders"
generate_traffic "catalog" "catalog" 8082 "/catalogue"

echo ""
echo "=== Fault Injection Active ==="
echo ""
echo "Check application logs for errors:"
echo "  kubectl logs -n orders -l app.kubernetes.io/name=orders --tail=50"
echo "  kubectl logs -n catalog -l app.kubernetes.io/name=catalog --tail=50"
echo ""
echo "Rollback:"
echo "  ./fault-injection/rollback-rds-sg-block.sh"
