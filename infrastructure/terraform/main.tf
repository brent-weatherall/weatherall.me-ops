# ------------------------------------------------------------------------------
# 1. TALOS IMAGE FACTORY
# Defines the OS extensions (ZFS, Guest Agent) via a schematic ID.
# ------------------------------------------------------------------------------
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/zfs",              # Storage
          "siderolabs/qemu-guest-agent", # Proxmox Integration
          "siderolabs/intel-ucode"       # CPU Microcode
        ]
      }
    }
  })
}

# ------------------------------------------------------------------------------
# 2. ISO DOWNLOAD
# Constructs the Factory URL and downloads it to Proxmox.
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "Local-ISOs" 
  node_name    = "pve"
  
  file_name    = "talos-v1.8.3-zfs.iso"
  
  # We construct the URL manually because the resource only outputs the ID.
  # Platform 'nocloud' allows Talos to read the IP config from Proxmox Cloud-Init.
  url = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/v1.8.3/nocloud-amd64.iso"
}

# ------------------------------------------------------------------------------
# 3. TALOS CONFIGURATION
# Generates the machine config (YAML) with patches for Static IPs & Istio.
# ------------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "talos-home"
  machine_type     = "controlplane"
  cluster_endpoint = "https://192.168.1.50:6443" # VIP (.50)
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
  cluster_endpoint = "https://192.168.1.50:6443"
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

# ------------------------------------------------------------------------------
# 4. VIRTUAL MACHINES
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
  
  memory {
    dedicated = 4096
    floating  = 2048 
  }

  agent { enabled = true }
  
  disk {
    datastore_id = "storage-pool"
    file_format  = "raw"
    interface    = "scsi0"
    size         = 20
    ssd          = true 
    discard      = "on" 
  }

  # IMPORTANT: This block generates a Cloud-Init drive.
  # Since we use the 'nocloud' ISO, Talos reads this for the initial Static IP.
  initialization {
    ip_config {
      ipv4 {
        address = "192.168.1.51/24"
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
# ------------------------------------------------------------------------------
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = "192.168.1.51"
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = 2
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  node                        = "192.168.1.${52 + count.index}"
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
