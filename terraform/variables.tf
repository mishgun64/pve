variable "proxmox_api_url" {
  type        = string
}

variable "proxmox_api_token_id" {
  type        = string
}

variable "control_ssh_key" {
  type        = string
}

variable "lxc_ostemplate" {
  type        = string
}

variable "memory" {
  type        = number
}

variable "cores" {
  type        = number
}

variable "storage_size" {
  type        = string
}

variable "ip_address" {
  type        = list(string)
}

variable "target_node_name" {
  type        = string
}

variable "webhook_token" {
  type        = string
}