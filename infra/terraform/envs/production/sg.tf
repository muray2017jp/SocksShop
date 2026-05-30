resource "aws_security_group" "node_additional" {
  name        = "node-additional"
  description = "Additional security group for EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "10.0.0.0/16"
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"

    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    Name = "node-additional"
  }
}