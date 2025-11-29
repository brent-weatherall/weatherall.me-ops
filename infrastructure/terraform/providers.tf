terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket                      = "homelab-tf-state" # Your bucket name
    key                         = "talos/terraform.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }

  required_providers {
    # Validated as latest stable for Nov 2025
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.86.0" 
    }

    talos = {
      source  = "siderolabs/talos"
      version = "0.9.0"
    }
  }
}

variable "virtual_environment_endpoint" {
  type        = string
  description = "The URL of the Proxmox API (e.g. https://192.168.1.4:8006/)"
}

variable "virtual_environment_api_token" {
  type        = string
  description = "The API Token (User!TokenName=UUID)"
  sensitive   = true
}

provider "proxmox" {
  endpoint  = var.virtual_environment_endpoint
  api_token = var.virtual_environment_api_token

  # Necessary for homelabs with self-signed certs
  insecure = true 
  
  ssh {
    agent = true
  }
}

provider "talos" {
  # No configuration needed for the provider itself
}
