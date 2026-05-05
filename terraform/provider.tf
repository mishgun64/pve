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
  username  = "root@pam"
  password  = var.proxmox_password
}