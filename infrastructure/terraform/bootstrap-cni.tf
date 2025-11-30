resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.16.1"
  namespace  = "kube-system"

  # Fire and Forget: Prevents "waiting for pods" deadlock
  wait       = false  
  timeout    = 600

  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_kubeconfig.this
  ]

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

resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]
  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "homelab-pool" }
    spec = {
      cidrs = ["192.168.1.60/32", "192.168.1.61/32"]
      serviceSelector = {
        matchLabels = { "io.cilium/lb-ip-pool" = "homelab-pool" }
      }
    }
  }
}

resource "kubernetes_manifest" "cilium_l2_policy" {
  depends_on = [helm_release.cilium]
  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "homelab-policy" }
    spec = {
      nodeSelector = { matchExpressions = [{ key = "node-role.kubernetes.io/control-plane", operator = "DoesNotExist" }] }
      interfaces = ["eth0"]
      externalIPs = true
      loadBalancerIPs = true
    }
  }
}