terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket                      = "homelab-tf-state"
    key                         = "talos/cluster_v1.tfstate"
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
    helm = {
      source  = "hashicorp/helm"
      version = "2.16.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.33.0"
    }
  }
}

variable "virtual_environment_endpoint" {
  type        = string
  description = "The URL of the Proxmox API"
}

variable "virtual_environment_api_token" {
  type        = string
  description = "The API Token"
  sensitive   = true
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

# ------------------------------------------------------------------------------
# KUBERNETES & HELM PROVIDERS
# Connection uses data from main.tf, which is explicitly set to Physical IP (.51)
# ------------------------------------------------------------------------------

provider "kubernetes" {
  host                   = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}