#------------------------------------Media VM------------------------------------

resource "proxmox_virtual_environment_vm" "media_vm" {
  vm_id     = 124
  name      = "media"
  node_name = var.target_node_name

  agent {
    enabled = true
  }

  clone {
    vm_id = var.debian_template_id
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 8192
  }

  boot_order = ["scsi0"]

  scsi_hardware = "virtio-scsi-single"

  started             = true
  on_boot             = true
  reboot_after_update = true

  startup {
    order    = "1"
    up_delay = "10"
  }

  initialization {
    datastore_id = "local-lvm"

    user_account {
      username = "root"
      keys     = [var.control_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "192.168.2.4/24"
        gateway = "192.168.2.1"
      }
    }

    dns {
      servers = ["192.168.2.1"]
    }

  }

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 30
    file_format  = "raw"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:F1:AB:F9"
    firewall    = true
  }

  serial_device {}
}

#------------------------------------Wireguard LXC------------------------------------

resource "proxmox_virtual_environment_container" "wireguard" {
  node_name = var.target_node_name
  vm_id     = 126

  unprivileged   = true
  started        = true
  start_on_boot  = true

  initialization {
    hostname = "wireguard"

    user_account {
      keys = [var.control_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "192.168.2.6/24"
        gateway = "192.168.2.1"
      }
    }
  }
  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:DB:27:39"
    firewall    = true
  }

  features {
    nesting = true
  }
}

#------------------------------------Traefik LXC------------------------------------

resource "proxmox_virtual_environment_container" "traefik" {
  node_name = var.target_node_name
  vm_id     = 143

  unprivileged   = true
  started        = true
  start_on_boot  = true

  initialization {
    hostname = "traefik"

    user_account {
      keys = [var.control_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "192.168.4.3/24"
        gateway = "192.168.4.1"
      }
    }

    ip_config {
      ipv4 {
        address = "192.168.2.3/24"
      }
    }
  }

  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr1"
    mac_address = "BC:24:11:DB:27:40"
    firewall    = true
  }

  network_interface {
    name        = "eth1"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:DB:27:41"
    firewall    = true
  }

  features {
    nesting = true
  }
}

#------------------------------------Prosody LXC------------------------------------

resource "proxmox_virtual_environment_container" "prosody" {
  node_name = var.target_node_name
  vm_id     = 144

  unprivileged  = true
  started       = true
  start_on_boot = true

  initialization {
    hostname = "prosody"

    user_account {
      keys = [var.control_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "192.168.4.4/24"
        gateway = "192.168.4.1"
      }
    }

    ip_config {
      ipv4 {
        address = "192.168.2.7/24"
      }
    }
  }

  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 7
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr1"
    mac_address = "BC:24:11:DB:27:42"
    firewall    = true
  }

  network_interface {
    name        = "eth1"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:DB:27:43"
    firewall    = true
  }

  features {
    nesting = true
  }
}

#------------------------------------Media_vm webhook trigger------------------------------------

resource "terraform_data" "media_vm_trigger" {
  depends_on = [proxmox_virtual_environment_vm.media_vm]
    lifecycle {
      replace_triggered_by = [proxmox_virtual_environment_vm.media_vm]
    }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=${var.webhook_token}" \
      -H "Content-Type: application/json" \
      -d '{"event": "media_vm"}'
    EOT
  }
}

#------------------------------------Wireguard webhook trigger------------------------------------

resource "terraform_data" "wireguard_trigger" {
  depends_on = [proxmox_virtual_environment_container.wireguard]
    lifecycle {
      replace_triggered_by = [proxmox_virtual_environment_container.wireguard]
    }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=${var.webhook_token}" \
      -H "Content-Type: application/json" \
      -d '{"event": "wireguard"}'
    EOT
  }
}

#------------------------------------Traefik webhook trigger------------------------------------

resource "terraform_data" "traefik_trigger" {
  depends_on = [proxmox_virtual_environment_container.traefik]
    lifecycle {
      replace_triggered_by = [proxmox_virtual_environment_container.traefik]
    }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=${var.webhook_token}" \
      -H "Content-Type: application/json" \
      -d '{"event": "traefik"}'
    EOT
  }
}

#------------------------------------Prosody webhook trigger------------------------------------

resource "terraform_data" "prosody_trigger" {
  depends_on = [proxmox_virtual_environment_container.prosody]
    lifecycle {
      replace_triggered_by = [proxmox_virtual_environment_container.prosody]
    }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=${var.webhook_token}" \
      -H "Content-Type: application/json" \
      -d '{"event": "prosody"}'
    EOT
  }
}