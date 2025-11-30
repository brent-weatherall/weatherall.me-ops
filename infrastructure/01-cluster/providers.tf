terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket                      = "homelab-tf-state"
    key                         = "talos/cluster.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    skip_s3_checksum            = true
  }

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.66.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.6.1"
    }
    # Added for local template rendering
    helm = {
      source  = "hashicorp/helm"
      version = "2.16.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.virtual_environment_endpoint
  api_token = var.virtual_environment_api_token
  insecure  = true 
  ssh {
    agent = false
  }
}

provider "talos" {}

# No config needed - just the binary for templating
provider "helm" {}