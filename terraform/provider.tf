terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
  }
}

provider "proxmox" {
  insecure  = true
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${file("./secrets/api_key")}"
}