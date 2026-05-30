output "alb_dns_name" {
  description = "SocksShop ALB の DNS名"
  value       = data.aws_lb.sockshop.dns_name
}

output "sockshop_url" {
  description = "SocksShop アクセスURL"
  value       = "https://sockshop.jyouhou.net"
}
