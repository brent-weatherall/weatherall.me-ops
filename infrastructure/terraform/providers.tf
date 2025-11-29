terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket                      = "homelab-tf-state"
    key                         = "talos/terraform.tfstate"
    
    # 1. Region Validation
    # R2 ignores regions, but Terraform demands one. "auto" or "us-east-1" is fine.
    region                      = "auto"
    skip_region_validation      = true
    
    # 2. Account ID Validation (CRITICAL)
    # R2 does not support the AWS "GetCallerIdentity" call.
    skip_requesting_account_id  = true
    
    # 3. Credential Validation
    # R2 does not use AWS IAM, so we skip standard AWS checks.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    
    # 4. Checksums (CRITICAL FOR 403 ERRORS)
    # R2 handles checksums differently than AWS S3.
    skip_s3_checksum            = true
    
    # 5. Path Style
    # R2 requires path-style access (https://endpoint/bucket), not domain-style.
    use_path_style              = true
    
    # NOTE: We do NOT define 'endpoints' here. 
    # We inject AWS_ENDPOINT_URL_S3 via GitHub Secrets.
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
    agent = false
  }
}

provider "talos" {
  # No configuration needed for the provider itself
}

provider "kubernetes" {
  host = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

# Ensure Helm uses the same creds
provider "helm" {
  kubernetes {
    host = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}
