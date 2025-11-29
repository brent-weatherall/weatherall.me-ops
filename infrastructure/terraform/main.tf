terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.66.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.6.1"
    }
  }
}

# ------------------------------------------------------------------------------
# 1. TALOS IMAGE FACTORY
# Generates a custom ISO with ZFS and QEMU Guest Agent extensions
# ------------------------------------------------------------------------------
data "talos_image_factory_extensions_versions" "this" {
  # Validated stable version for Nov 2025 context
  talos_version = "v1.8.3" 
  filters = {
    names = [
      "zfs",              # Required for OpenEBS LocalPV ZFS storage
      "qemu-guest-agent", # Required for Proxmox UI IP display & Shutdowns
      "intel-ucode"       # Recommended for Intel CPUs
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = data.talos_image_factory_extensions_versions.this.right
}

# ------------------------------------------------------------------------------
# 2. ISO DOWNLOAD
# Tells Proxmox to download the generated ISO to your Local-ISOs storage
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "Local-ISOs"  # <--- MUST MATCH YOUR ISO STORAGE ID
  node_name    = "pve"         # <--- Change if your node is named differently
  
  file_name    = "talos-${data.talos_image_factory_extensions_versions.this.talos_version}-zfs.iso"
  url          = "${talos_image_factory_schematic.this.id.urls.iso}"
}

# ------------------------------------------------------------------------------
# 3. TALOS CONFIGURATION
# Generates the machine config (YAML) with patches for Static IPs & Istio
# ------------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "talos-home"
  machine_type     = "controlplane"
  cluster_endpoint = "https://192.168.1.50:6443" # Pointing to the VIP (.50)
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = data.talos_image_factory_extensions_versions.this.talos_version
  
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-cp-01"
          interfaces = [{
            interface = "eth0"
            dhcp      = false
            addresses = ["192.168.1.51/24"] # Physical IP (.51)
            routes    = [{ network = "0.0.0.0/0", gateway = "192.168.1.1" }]
            vip       = { ip = "192.168.1.50" } # The VIP (.50) managed by this node
          }]
          nameservers = ["1.1.1.1", "192.168.1.1"]
        }
        # ISTIO REQUIREMENT: Enable IP forwarding
        sysctls = {
          "net.ipv4.ip_forward"          = "1"
          "net.ipv6.conf.all.forwarding" = "1"
        }
      }
      cluster = {
        # CILIUM/ISTIO REQUIREMENT: Disable default CNI & KubeProxy
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  count            = 2
  cluster_name     = "talos-home"
  machine_type     = "worker"
  cluster_endpoint = "https://192.168.1.50:6443" # Workers talk to the VIP
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = data.talos_image_factory_extensions_versions.this.talos_version
  
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-worker-${count.index + 1}"
          interfaces = [{
            interface = "eth0"
            dhcp      = false
            # Logic: Starts at .52 (52 + 0 = 52, 52 + 1 = 53)
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

# ------------------------------------------------------------------------------
# 4. VIRTUAL MACHINES
# Creates the VMs in Proxmox with Memory Ballooning enabled
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "controlplane" {
  name        = "talos-cp-01"
  node_name   = "pve"
  vm_id       = 200
  tags        = ["k8s", "talos", "control-plane"]
  
  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }
  
  # RAM OPTIMIZATION: Max 4GB, Min 2GB
  memory {
    dedicated = 4096
    floating  = 2048 
  }

  agent { enabled = true }
  
  disk {
    datastore_id = "storage-pool" # <--- MUST MATCH YOUR ZPOOL STORAGE ID
    file_format  = "raw"
    interface    = "scsi0"
    size         = 20
    ssd          = true 
    discard      = "on" 
  }

  initialization {
    ip_config {
      ipv4 {
        address = "192.168.1.51/24" # Physical IP
        gateway = "192.168.1.1"
      }
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }
  
  operating_system {
    type = "l26" # Linux 2.6+
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count       = 2
  name        = "talos-worker-${count.index + 1}"
  node_name   = "pve"
  vm_id       = 300 + count.index
  tags        = ["k8s", "talos", "worker"]
  
  cpu {
    cores = 4
    type  = "x86-64-v2-AES"
  }
  
  # RAM OPTIMIZATION: Max 8GB, Min 4GB
  memory {
    dedicated = 8192
    floating  = 4096 
  }

  agent { enabled = true }

  disk {
    datastore_id = "storage-pool"
    file_format  = "raw"
    interface    = "scsi0"
    size         = 50
    ssd          = true
    discard      = "on"
  }

  initialization {
    ip_config {
      ipv4 {
        # Logic: 192.168.1.52, .53
        address = "192.168.1.${52 + count.index}/24"
        gateway = "192.168.1.1"
      }
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }
  
  operating_system {
    type = "l26"
  }
}

# ------------------------------------------------------------------------------
# 5. BOOTSTRAP
# Pushes config to the nodes and bootstraps the cluster
# ------------------------------------------------------------------------------
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = "192.168.1.51" # Target the Physical IP, NOT the VIP
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = 2
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  node                        = "192.168.1.${52 + count.index}"
}

resource "talos_cluster_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51" # Bootstrap via Physical IP
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_cluster_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51"
}

# ------------------------------------------------------------------------------
# 6. OUTPUTS
# ------------------------------------------------------------------------------
output "talosconfig" {
  value     = talos_machine_secrets.this.client_configuration
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
