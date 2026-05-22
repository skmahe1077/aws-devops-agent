# =============================================================================
# Kubernetes Namespaces and Application Deployments
# =============================================================================

resource "time_sleep" "workloads" {
  create_duration  = "30s"
  destroy_duration = "60s"

  depends_on = [module.eks]
}

# =============================================================================
# IngressClass for ALB (EKS Auto Mode)
# =============================================================================

resource "null_resource" "ingress_class" {
  depends_on = [time_sleep.workloads]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CLUSTER_NAME = var.cluster_name
      REGION       = var.region
    }

    command = <<-EOT
      aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
      cat <<EOF | kubectl apply -f -
apiVersion: eks.amazonaws.com/v1
kind: IngressClassParams
metadata:
  name: alb
spec:
  scheme: internet-facing
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: eks.amazonaws.com/alb
  parameters:
    apiGroup: eks.amazonaws.com
    kind: IngressClassParams
    name: alb
EOF
    EOT
  }
}

# =============================================================================
# Catalog Service (Aurora MySQL - WILL FAIL due to SG bug)
# =============================================================================

resource "kubernetes_namespace_v1" "catalog" {
  depends_on = [time_sleep.workloads]

  metadata {
    name = "catalog"
  }
}

resource "helm_release" "catalog" {
  name       = "catalog"
  repository = "oci://public.ecr.aws/aws-containers"
  chart      = "retail-store-sample-catalog-chart"
  version    = "1.3.0"

  namespace = kubernetes_namespace_v1.catalog.metadata[0].name

  values = [<<-YAML
    securityGroups:
      create: false

    app:
      persistence:
        provider: mysql
        endpoint: "${aws_rds_cluster.catalog.endpoint}:${aws_rds_cluster.catalog.port}"

        secret:
          username: admin
          password: "${random_string.catalog_db_master.result}"
  YAML
  ]
}

# =============================================================================
# Orders Service (Aurora PostgreSQL - WILL FAIL due to SG bug)
# =============================================================================

resource "kubernetes_namespace_v1" "orders" {
  depends_on = [time_sleep.workloads]

  metadata {
    name = "orders"
  }
}

resource "helm_release" "orders" {
  name       = "orders"
  repository = "oci://public.ecr.aws/aws-containers"
  chart      = "retail-store-sample-orders-chart"
  version    = "1.3.0"

  namespace = kubernetes_namespace_v1.orders.metadata[0].name

  values = [<<-YAML
    securityGroups:
      create: false

    app:
      persistence:
        provider: postgres
        endpoint: "${aws_rds_cluster.orders.endpoint}:${aws_rds_cluster.orders.port}"
        database: orders

        secret:
          username: dbadmin
          password: "${random_string.orders_db_master.result}"
  YAML
  ]
}

# =============================================================================
# Carts Service (DynamoDB - no RDS issue)
# =============================================================================

resource "kubernetes_namespace_v1" "carts" {
  depends_on = [time_sleep.workloads]

  metadata {
    name = "carts"
  }
}

resource "helm_release" "carts" {
  name       = "carts"
  repository = "oci://public.ecr.aws/aws-containers"
  chart      = "retail-store-sample-cart-chart"
  version    = "1.3.0"

  namespace = kubernetes_namespace_v1.carts.metadata[0].name
}

# =============================================================================
# UI Service (exposed via ALB Ingress - public website)
# =============================================================================

resource "kubernetes_namespace_v1" "ui" {
  depends_on = [time_sleep.workloads]

  metadata {
    name = "ui"
  }
}

resource "helm_release" "ui" {
  depends_on = [
    null_resource.ingress_class,
    helm_release.catalog,
    helm_release.carts,
    helm_release.orders,
  ]

  name       = "ui"
  repository = "oci://public.ecr.aws/aws-containers"
  chart      = "retail-store-sample-ui-chart"
  version    = "1.3.0"

  namespace = kubernetes_namespace_v1.ui.metadata[0].name

  values = [<<-YAML
    app:
      endpoints:
        catalog: http://catalog.catalog.svc:80
        carts: http://carts.carts.svc:80
        orders: http://orders.orders.svc:80

    service:
      type: ClusterIP

    ingress:
      enabled: true
      className: alb
      annotations:
        alb.ingress.kubernetes.io/scheme: internet-facing
        alb.ingress.kubernetes.io/target-type: ip
        alb.ingress.kubernetes.io/healthcheck-path: /actuator/health/liveness
  YAML
  ]
}

# =============================================================================
# Fetch the ALB URL after UI ingress is created
# =============================================================================

resource "time_sleep" "wait_for_alb" {
  create_duration = "60s"

  depends_on = [helm_release.ui]
}

data "kubernetes_ingress_v1" "ui" {
  depends_on = [time_sleep.wait_for_alb]

  metadata {
    name      = "ui"
    namespace = "ui"
  }
}
