resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  version = "3.12.2"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  set {
    name  = "args[1]"
    value = "--kubelet-preferred-address-types=InternalIP"
  }

  set {
    name  = "args[2]"
    value = "--metric-resolution=15s"
  }

  # read-only rootファイルシステムを無効化（bool型で渡す）
  set {
    name  = "containerSecurityContext.readOnlyRootFilesystem"
    value = "false"
    type  = "auto"
  }

  wait    = true
  timeout = 300

  depends_on = [
    module.eks
  ]
}
