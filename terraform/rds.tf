# =============================================================================
# RDS Security Groups
# =============================================================================

# BUG: The RDS security groups only allow access from their own security group,
# NOT from the EKS node security group. This means services running on EKS
# cannot connect to the database.
#
# The correct configuration should include an ingress rule allowing traffic
# from module.eks.node_security_group_id on the respective database ports.

resource "aws_security_group" "catalog_rds" {
  name_prefix = "${var.cluster_name}-catalog-rds-"
  description = "Security group for Catalog Aurora MySQL"
  vpc_id      = module.vpc.vpc_id

  # Only allows access from itself - EKS nodes CANNOT reach the database
  ingress {
    description = "MySQL from self"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-catalog-rds"
    Environment = var.cluster_name
  }
}

resource "aws_security_group" "orders_rds" {
  name_prefix = "${var.cluster_name}-orders-rds-"
  description = "Security group for Orders Aurora PostgreSQL"
  vpc_id      = module.vpc.vpc_id

  # Only allows access from itself - EKS nodes CANNOT reach the database
  ingress {
    description = "PostgreSQL from self"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-orders-rds"
    Environment = var.cluster_name
  }
}

# =============================================================================
# DB Subnet Group (shared by both Aurora clusters)
# =============================================================================

resource "aws_db_subnet_group" "this" {
  name       = "${var.cluster_name}-db-subnet"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name        = "${var.cluster_name}-db-subnet"
    Environment = var.cluster_name
  }
}

# =============================================================================
# Catalog Aurora MySQL (native resources - full SG control)
# =============================================================================

resource "random_string" "catalog_db_master" {
  length  = 10
  special = false
}

resource "aws_rds_cluster_parameter_group" "catalog" {
  name   = "${var.cluster_name}-catalog"
  family = "aurora-mysql8.0"

  tags = {
    Environment = var.cluster_name
  }
}

resource "aws_rds_cluster" "catalog" {
  cluster_identifier = "${var.cluster_name}-catalog"
  engine             = "aurora-mysql"
  engine_version     = "8.0"

  database_name   = "catalog"
  master_username = "admin"
  master_password = random_string.catalog_db_master.result

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.catalog_rds.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.catalog.name

  storage_encrypted   = true
  apply_immediately   = true
  skip_final_snapshot = true

  tags = {
    Environment = var.cluster_name
  }
}

resource "aws_rds_cluster_instance" "catalog" {
  identifier         = "${var.cluster_name}-catalog-one"
  cluster_identifier = aws_rds_cluster.catalog.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.catalog.engine
  engine_version     = aws_rds_cluster.catalog.engine_version

  apply_immediately = true

  tags = {
    Environment = var.cluster_name
  }
}

# =============================================================================
# Orders Aurora PostgreSQL (native resources - full SG control)
# =============================================================================

resource "random_string" "orders_db_master" {
  length  = 10
  special = false
}

resource "aws_rds_cluster_parameter_group" "orders" {
  name   = "${var.cluster_name}-orders"
  family = "aurora-postgresql15"

  tags = {
    Environment = var.cluster_name
  }
}

resource "aws_rds_cluster" "orders" {
  cluster_identifier = "${var.cluster_name}-orders"
  engine             = "aurora-postgresql"
  engine_version     = "15.10"

  database_name   = "orders"
  master_username = "dbadmin"
  master_password = random_string.orders_db_master.result

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.orders_rds.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.orders.name

  storage_encrypted   = true
  apply_immediately   = true
  skip_final_snapshot = true

  tags = {
    Environment = var.cluster_name
  }
}

resource "aws_rds_cluster_instance" "orders" {
  identifier         = "${var.cluster_name}-orders-one"
  cluster_identifier = aws_rds_cluster.orders.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.orders.engine
  engine_version     = aws_rds_cluster.orders.engine_version

  apply_immediately = true

  tags = {
    Environment = var.cluster_name
  }
}
