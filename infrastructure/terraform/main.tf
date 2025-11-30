# ------------------------------------------------------------------------------
# 1. TALOS IMAGE FACTORY
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 2. ISO DOWNLOAD
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "Local-ISOs" 
  node_name    = "pve"
  
  file_name    = "talos-v1.8.3-zfs.iso"
  url          = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/v1.8.3/nocloud-amd64.iso"
  overwrite    = true
}

# ------------------------------------------------------------------------------
# 3. TALOS CONFIGURATION
# ------------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "talos-home"
  machine_type     = "controlplane"
  
  # CRITICAL: Bootstrap using PHYSICAL IP (.51) to avoid VIP deadlock
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
            addresses = ["192.168.1.51/24"] # Physical IP
            routes    = [{ network = "0.0.0.0/0", gateway = "192.168.1.1" }]
            vip       = { ip = "192.168.1.50" } # Virtual IP (Future Use)
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

data "talos_machine_configuration" "worker" {
  count            = 2
  cluster_name     = "talos-home"
  machine_type     = "worker"
  cluster_endpoint = "https://192.168.1.51:6443" # Workers connect to Physical IP
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
  boot_order  = ["ide3", "scsi0", "net0"]

  cpu {
    cores = 2
    type  = "host"
  }
  
  memory {
    dedicated = 4096
    floating  = 2048
  }

  agent { enabled = false } # Disabled to prevent Terraform refresh hang
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

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    enabled   = true
    interface = "ide3"
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
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
  boot_order  = ["ide3", "scsi0", "net0"]
  
  cpu {
    cores = 4
    type  = "host"
  }
  
  memory {
    dedicated = 8192
    floating  = 4096
  }

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
    enabled   = true
    interface = "ide3"
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
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
  node                        = "192.168.1.51" # Physical IP
  depends_on                  = [proxmox_virtual_environment_vm.controlplane]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = 2
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  node                        = "192.168.1.${52 + count.index}" # Physical IP
  depends_on                  = [proxmox_virtual_environment_vm.worker]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51" # Physical IP
}

# ------------------------------------------------------------------------------
# 6. DATA SOURCES & OUTPUTS
# ------------------------------------------------------------------------------
# This Data Source reads the config BACK from the cluster.
# We force it to read from .51 (Physical) so the Helm Provider can connect.
data "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.1.51"
}

# This Data Source generates the config for YOU (the user).
# We force this to .51 for now so your laptop works immediately.
data "talos_client_configuration" "this" {
  cluster_name         = "talos-home"
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = ["192.168.1.51"]
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}