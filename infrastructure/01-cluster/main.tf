# 1. IMAGE FACTORY
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/zfs",
          "siderolabs/qemu-guest-agent",
          "siderolabs/intel-ucode"
        ]
      }
    }
  })
}

# 2. ISO DOWNLOAD
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "Local-ISOs"
  node_name    = "pve"
  file_name    = "talos-v1.8.3-zfs.iso"
  url          = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/v1.8.3/nocloud-amd64.iso"
  overwrite    = true
}

# ------------------------------------------------------------------------------
# NEW: RENDER CILIUM MANIFEST LOCALLY
# This generates the YAML but does not try to install it.
# ------------------------------------------------------------------------------
data "helm_template" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.16.1"
  namespace  = "kube-system"

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

# 3. CONFIG GENERATION
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "talos-home"
  machine_type     = "controlplane"
  cluster_endpoint = "https://192.168.1.51:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = "v1.8.3"
  
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-cp-01"
          interfaces = [{
            interface = "eth0"
            dhcp      = false
            addresses = ["192.168.1.51/24"]
            routes    = [{ network = "0.0.0.0/0", gateway = "192.168.1.1" }]
            vip       = { ip = "192.168.1.50" }
          }]
          nameservers = ["1.1.1.1", "192.168.1.1"]
        }
        sysctls = {
          "net.ipv4.ip_forward"          = "1"
          "net.ipv6.conf.all.forwarding" = "1"
        }
      }
      cluster = {
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
        
        # THE FIX: Inject Cilium Manifest directly into Talos Config
        inlineManifests = [
          {
            name     = "cilium"
            contents = data.helm_template.cilium.manifest
          }
        ]
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  count            = 2
  cluster_name     = "talos-home"
  machine_type     = "worker"
  cluster_endpoint = "https://192.168.1.51:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = "v1.8.3"
  
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-worker-${count.index + 1}"
          interfaces = [{
            interface = "eth0"
            dhcp      = false
            addresses = ["192.168.1.${52 + count.index}/24"] 
            routes    = [{ network = "0.0.0.0/0", gateway = "192.168.1.1" }]
          }]
          nameservers = ["1.1.1.1", "192.168.1.1"]
        }
        sysctls = {
          "net.ipv4.ip_forward"          = "1"
          "net.ipv6.conf.all.forwarding" = "1"
        }
      }
      cluster = {
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
      }
    })
  ]
}

# 4. VIRTUAL MACHINES
resource "proxmox_virtual_environment_vm" "controlplane" {
  name        = "talos-cp-01"
  node_name   = "pve"
  vm_id       = 200
  tags        = ["k8s", "talos", "control-plane"]
  boot_order  = ["scsi0", "ide3", "net0"] # Hard Drive First

  cpu {
    cores = 2
    type  = "host"
  }
  
  memory {
    dedicated = 4096
    floating  = 2048
  }

  agent { enabled = false }
  depends_on = [proxmox_virtual_environment_download_file.talos_iso]

  disk {
    datastore_id = "storage-pool"
    file_format  = "raw"
    interface    = "scsi0"
    size         = 20
    ssd          = true
    discard      = "on"
  }

  initialization {
    interface = "ide2"
    ip_config {
      ipv4 {
        address = "192.168.1.51/24"
        gateway = "192.168.1.1"
      }
    }
  }

  network_device { bridge = "vmbr0" }
  cdrom { enabled = true, interface = "ide3", file_id = proxmox_virtual_environment_download_file.talos_iso.id }
  operating_system { type = "l26" }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count       = 2
  name        = "talos-worker-${count.index + 1}"
  node_name   = "pve"
  vm_id       = 300 + count.index
  tags        = ["k8s", "talos", "worker"]
  boot_order  = ["scsi0", "ide3", "net0"] # Hard Drive First
  
  cpu { cores = 4, type = "host" }
  memory { dedicated = 8192, floating = 4096 }
  agent { enabled = false }
  depends_on = [proxmox_virtual_environment_download_file.talos_iso]

  disk {
    datastore_id = "storage-pool"
    file_format  = "raw"
    interface    = "scsi0"
    size         = 50
    ssd          = true
    discard      = "on"
  }

  initialization {
    interface = "ide2"
    ip_config {
      ipv4 { address = "192.168.1.${52 + count.index}/24", gateway = "192.168.1.1" }
    }
  }

  network_device { bridge = "vmbr0" }
  cdrom { enabled = true, interface = "ide3", file_id = proxmox_virtual_environment_download_file.talos_iso.id }
  operating_system { type = "l26" }
}

# 5. BOOTSTRAP
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = "192.168.1.51"
  depends_on                  = [proxmox_virtual_environment_vm.controlplane]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = 2
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  node                        = "192.168.1.${52 + count.index}"
  depends_on                  = [proxmox_virtual_environment_vm.worker]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51"
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51"
}

data "talos_client_configuration" "this" {
  cluster_name         = "talos-home"
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = ["192.168.1.51"]
}