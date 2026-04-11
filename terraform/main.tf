#------------------------------------Media VM------------------------------------

resource "proxmox_vm_qemu" "media_vm" {
  vmid        = 124
  name        = "media"
  target_node = var.target_node_name
  agent       = 1
  memory      = 8192
  boot        = "order=scsi0"
  clone       = "debian-cloudinit-template"
  scsihw      = "virtio-scsi-single"
  vm_state    = "running"
  automatic_reboot = true
  start_at_node_boot = true

  # Cloud-Init configuration
  cicustom   = "vendor=local:snippets/qemu-guest-agent.yml" # /var/lib/vz/snippets/qemu-guest-agent.yml
  ciupgrade  = true
  nameserver = "192.168.2.1"
  ipconfig0  = "ip=192.168.2.4/24,gw=192.168.2.1"
  skip_ipv6  = true
  ciuser     = "root"
  # cipassword = "1234"
  sshkeys    = var.control_ssh_key

  startup_shutdown {
  order         = 1
  startup_delay = 10
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }

  # Most cloud-init images require a serial device for their display
  serial {
    id = 0
  }

  disks {
    scsi {
      scsi0 {
        # We have to specify the disk from our template, else Terraform will think it's not supposed to be there
        disk {
          storage = "local-lvm"
          # The size of the disk should be at least as big as the disk in the template. If it's smaller, the disk will be recreated
          size    = "30G"
        }
      }
    }
    ide {
      # Some images require a cloud-init disk on the IDE controller, others on the SCSI or SATA controller
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  #   virtio {
  #     virtio1 {
  #       passthrough {
  #         file   = "/dev/media_vg/media_lv"
  #         backup = false
  #       }
  #     }
  #   }
  }

  network {
    id = 0
    bridge = "vmbr0"
    model  = "virtio"
    macaddr = "bc:24:11:f1:ab:f9"
  }
}

#------------------------------------Wireguard LXC------------------------------------

resource "proxmox_lxc" "wireguard" {
  target_node     = var.target_node_name
  vmid            = 126
  hostname        = "wireguard"
  ostemplate      = var.lxc_ostemplate
  # password        = "12345"
  unprivileged    = true
  cores           = 1
  memory          = 1024
  start           = true
  onboot          = true
  ssh_public_keys = var.control_ssh_key

  rootfs {
    storage = "local-lvm"
    size    = "8G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "192.168.2.6/24"
    gw     = "192.168.2.1"
    hwaddr = "bc:24:11:db:27:39"
  }

  features {
    nesting = true
  }
}

#------------------------------------Traefik LXC------------------------------------

resource "proxmox_lxc" "traefik" {
  target_node     = var.target_node_name
  vmid            = 133
  hostname        = "traefik"
  ostemplate      = var.lxc_ostemplate
  # password        = "12345"
  unprivileged    = true
  cores           = 1
  memory          = 1024
  start           = true
  onboot          = true
  ssh_public_keys = var.control_ssh_key

  rootfs {
    storage = "local-lvm"
    size    = "8G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr1"
    ip     = "192.168.4.2/24"
    gw     = "192.168.4.1"
    hwaddr = "bc:24:11:db:27:40"
  }

  network {
  name   = "eth1"
  bridge = "vmbr0"
  ip     = "192.168.2.3/24"
  hwaddr = "bc:24:11:db:27:41"
  }

  features {
    nesting = true
  }
}

#------------------------------------Media_vm webhook trigger------------------------------------

resource "terraform_data" "media_vm_trigger" {
  depends_on = [proxmox_vm_qemu.media_vm]

  triggers_replace = {
    vm_id = proxmox_vm_qemu.media_vm.id
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
  depends_on = [proxmox_lxc.wireguard]

  triggers_replace = {
    vm_id = proxmox_lxc.wireguard.id
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
  depends_on = [proxmox_lxc.traefik]

  triggers_replace = {
    vm_id = proxmox_lxc.traefik.id
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