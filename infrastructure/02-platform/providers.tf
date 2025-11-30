terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket                      = "homelab-tf-state"
    key                         = "talos/platform.tfstate" # New state file
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    skip_s3_checksum            = true
  }

  required_providers {
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

provider "helm" {
  kubernetes {
    host                   = "https://${data.terraform_remote_state.cluster.outputs.control_plane_ip}:6443"
    client_certificate     = base64decode(data.terraform_remote_state.cluster.outputs.client_certificate)
    client_key             = base64decode(data.terraform_remote_state.cluster.outputs.client_key)
    cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_certificate)
  }
}