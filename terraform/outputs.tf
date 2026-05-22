output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "catalog_rds_endpoint" {
  description = "Catalog Aurora MySQL endpoint"
  value       = aws_rds_cluster.catalog.endpoint
}

output "orders_rds_endpoint" {
  description = "Orders Aurora PostgreSQL endpoint"
  value       = aws_rds_cluster.orders.endpoint
}

output "catalog_rds_security_group_id" {
  description = "Catalog RDS security group ID"
  value       = aws_security_group.catalog_rds.id
}

output "orders_rds_security_group_id" {
  description = "Orders RDS security group ID"
  value       = aws_security_group.orders_rds.id
}

output "eks_node_security_group_id" {
  description = "EKS node security group ID"
  value       = module.eks.node_security_group_id
}

output "retail_app_url" {
  description = "Retail Store Website URL"
  value       = try("http://${data.kubernetes_ingress_v1.ui.status[0].load_balancer[0].ingress[0].hostname}", "ALB not ready yet - run: kubectl get ingress -n ui")
}
