variable "cluster_name" {
  default = "eks-example"
}

data "aws_lb" "sockshop" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
  }
}
