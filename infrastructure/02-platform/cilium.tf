resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.16.1"
  namespace  = "kube-system"

  # We can wait now because Layer 1 ensured the cluster exists
  wait       = true  
  timeout    = 600

  values = [
    yamlencode({
      ipam = { mode = "kubernetes" }
      kubeProxyReplacement = true
      securityContext = {
        capabilities = {
          ciliumAgent = ["CHOWN","KILL","NET_ADMIN","NET_RAW","IPC_LOCK","SYS_ADMIN","SYS_RESOURCE","DAC_OVERRIDE","FOWNER","SETGID","SETUID"]
          cleanCiliumState = ["NET_ADMIN","SYS_ADMIN","SYS_RESOURCE"]
        }
      }
      cgroup = { autoMount = { enabled = false } }
      hostRoot = "/sys/fs/cgroup"
      k8sServiceHost = "127.0.0.1"
      k8sServicePort = "7445"
      cni = { exclusive = false }
      l7Proxy = false
      l2announcements = { enabled = true }
      externalIPs = { enabled = true }
    })
  ]
}