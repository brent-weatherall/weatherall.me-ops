variable "virtual_environment_endpoint" {
  type        = string
  description = "The URL of the Proxmox API (e.g., https://192.168.1.51:8006/)"
}

variable "virtual_environment_api_token" {
  type        = string
  description = "The API Token (User!TokenName=UUID)"
  sensitive   = true
}