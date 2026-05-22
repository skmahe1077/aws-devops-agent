# AWS DevOps Agent Demo - Services Won't Connect to Database

This project deploys an EKS cluster with a retail store microservices application that has an **intentional security group misconfiguration** — services running on EKS cannot connect to their RDS databases. The retail store website is publicly accessible via ALB so you can **visually see the impact** during the demo.

## Architecture

```
                         ┌──────────────┐
                         │   Internet   │
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │  AWS ALB     │
                         │  (Ingress)   │
                         └──────┬───────┘
                                │
┌───────────────────────────────┼─────────────────────────────┐
│                        VPC (10.0.0.0/16)                    │
│                               │                             │
│  ┌────────────────────────────┼──────────────────────────┐  │
│  │              EKS Cluster (Auto Mode)                  │  │
│  │                            │                          │  │
│  │                     ┌──────▼──────┐                   │  │
│  │                     │  UI Service │                   │  │
│  │                     │  (Website)  │                   │  │
│  │                     └──┬───┬───┬──┘                   │  │
│  │                  ┌─────┘   │   └──────┐               │  │
│  │           ┌──────▼───┐ ┌──▼─────┐ ┌──▼───────┐       │  │
│  │           │ Catalog  │ │ Orders │ │  Carts   │       │  │
│  │           │ Service  │ │Service │ │ Service  │       │  │
│  │           └────┬─────┘ └───┬────┘ └──────────┘       │  │
│  │                │           │                          │  │
│  │           ✗ BLOCKED   ✗ BLOCKED                       │  │
│  │                │           │                          │  │
│  └────────────────┼───────────┼──────────────────────────┘  │
│                   │           │                              │
│            ┌──────▼──────┐ ┌─▼──────────────┐               │
│            │ Aurora MySQL│ │Aurora PostgreSQL│               │
│            │  (Catalog)  │ │    (Orders)    │               │
│            │ Port: 3306  │ │  Port: 5432    │               │
│            └─────────────┘ └────────────────┘               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## The Bug

The RDS security groups only allow ingress from **themselves** (`self = true`), missing ingress rules from the **EKS node security group**. This means:

- **Catalog service** cannot connect to Aurora MySQL on port 3306
- **Orders service** cannot connect to Aurora PostgreSQL on port 5432
- **Website impact**: The retail store loads but product catalog shows empty/errors and placing orders fails

## Demo Flow

### What the audience sees

1. **Open the website URL** (from Terraform output) in a browser
2. **Retail store loads** — the UI service is healthy
3. **Product catalog is broken** — no products displayed, errors loading catalog
4. **Orders fail** — attempting to place an order returns errors
5. **DevOps Agent investigates** — diagnoses the RDS security group misconfiguration
6. **Fix is applied** — add EKS node SG to RDS ingress rules
7. **Website works** — products appear, orders succeed

## Project Structure

```
.
├── README.md
├── terraform/
│   ├── versions.tf        # Provider configuration (AWS, Kubernetes, Helm)
│   ├── variables.tf       # Input variables (cluster name, region, VPC CIDR)
│   ├── vpc.tf             # VPC with 3 AZs, public/private subnets, NAT gateway
│   ├── eks.tf             # EKS cluster v1.34 with Auto Mode
│   ├── rds.tf             # Aurora MySQL + PostgreSQL with BUGGY security groups
│   ├── kubernetes.tf      # Helm releases + ALB Ingress for public website
│   └── outputs.tf         # kubectl config, website URL, security group IDs
└── fault-injection/
    ├── inject-rds-sg-block.sh    # Revoke EKS→RDS security group rules
    └── rollback-rds-sg-block.sh  # Restore revoked rules and verify
```

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [jq](https://jqlang.github.io/jq/) (for fault injection scripts)

## Quick Start

### 1. Deploy the Infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --name retail-store --region us-east-1
```

### 3. Open the Website

After `terraform apply` completes, it outputs the website URL:

```bash
# Get the URL
terraform output retail_app_url

# Or manually
kubectl get ingress -n ui
```

Open the URL in your browser. You'll see the retail store, but:
- **Product catalog** will show errors (catalog service can't reach MySQL)
- **Placing orders** will fail (orders service can't reach PostgreSQL)

### 4. Observe the Failure in CLI

```bash
# Pods may be in CrashLoopBackOff or showing errors
kubectl get pods -n catalog
kubectl get pods -n orders

# Check logs for database connection errors
kubectl logs -n catalog -l app.kubernetes.io/name=catalog --tail=20
kubectl logs -n orders -l app.kubernetes.io/name=orders --tail=20
```

### 5. Diagnose with DevOps Agent

Point your AWS DevOps Agent at this cluster and ask it to investigate why services can't connect to their databases. The agent should:

1. Check pod logs and identify database connection errors
2. Inspect RDS security groups
3. Compare with EKS node security group
4. Identify the missing ingress rules
5. Recommend or apply the fix

### 6. The Fix

Add EKS node security group ingress rules to each RDS security group in `terraform/rds.tf`:

```hcl
# Add to aws_security_group.catalog_rds
ingress {
  description     = "MySQL from EKS nodes"
  from_port       = 3306
  to_port         = 3306
  protocol        = "tcp"
  security_groups = [module.eks.node_security_group_id]
}

# Add to aws_security_group.orders_rds
ingress {
  description     = "PostgreSQL from EKS nodes"
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [module.eks.node_security_group_id]
}
```

Then apply and refresh the website:

```bash
terraform apply

# Restart pods to reconnect
kubectl rollout restart deployment -n catalog catalog
kubectl rollout restart deployment -n orders orders
```

Refresh the browser — products now load and orders work.

### 7. Cleanup

```bash
cd terraform
terraform destroy
```

## Fault Injection Scripts

These scripts can be used to simulate the issue on a **working** cluster (where the fix has already been applied):

| Script | Description |
|--------|-------------|
| `fault-injection/inject-rds-sg-block.sh` | Revokes EKS→RDS security group rules, restarts pods, and generates traffic to trigger errors |
| `fault-injection/rollback-rds-sg-block.sh` | Restores revoked rules from backup, restarts pods, and verifies connectivity |

```bash
# Inject the fault
./fault-injection/inject-rds-sg-block.sh

# Rollback
./fault-injection/rollback-rds-sg-block.sh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | `retail-store` | Name of the EKS cluster |
| `region` | `us-east-1` | AWS region |
| `vpc_cidr` | `10.0.0.0/16` | CIDR block for VPC |
| `cluster_version` | `1.34` | Kubernetes version |

Override via `terraform.tfvars`:

```hcl
cluster_name    = "my-demo-cluster"
region          = "eu-west-1"
cluster_version = "1.34"
```

## Services Deployed

| Service | Namespace | Database | Website Impact When Broken |
|---------|-----------|----------|---------------------------|
| Catalog | `catalog` | Aurora MySQL (port 3306) | No products displayed |
| Orders | `orders` | Aurora PostgreSQL (port 5432) | Cannot place orders |
| Carts | `carts` | DynamoDB (no issue) | Cart works normally |
| UI | `ui` | None (ALB Ingress) | Website loads but backend errors visible |
