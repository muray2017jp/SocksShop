module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  subnet_ids = module.vpc.private_subnets
  vpc_id     = module.vpc.vpc_id

  cluster_endpoint_public_access = true

  authentication_mode = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # AWS管理者ユーザー（GUI用）
    aws-admin = {
      principal_arn = "arn:aws:iam::455110051621:root"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    ng-1 = {
      desired_size = 2
      max_size     = 2
      min_size     = 2

      capacity_type = "SPOT"

      instance_types = [
        "t3.medium",
        "t3a.medium"
      ]

      update_config = {
        max_unavailable = 1
      }

      vpc_security_group_ids = [
        aws_security_group.node_additional.id
      ]
    }
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name

  depends_on = [
    module.eks
  ]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name

  depends_on = [
    module.eks
  ]
}
