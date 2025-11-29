# This purely reads data. It creates nothing.
data "proxmox_virtual_environment_version" "current" {}

# If this output appears in your CI logs, you have won.
output "proxmox_version" {
  value = data.proxmox_virtual_environment_version.current.version
}
