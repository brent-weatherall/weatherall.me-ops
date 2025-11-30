output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "control_plane_ip" {
  value = "192.168.1.51"
}

output "client_certificate" {
  value     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate
  sensitive = true
}

output "client_key" {
  value     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
  sensitive = true
}