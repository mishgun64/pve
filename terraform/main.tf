resource "proxmox_vm_qemu" "media_vm" {
  vmid        = 124
  name        = "media"
  target_node = "pve"
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
  ipconfig0  = "gw=192.168.2.1,ip=192.168.2.4/24"
  skip_ipv6  = true
  ciuser     = "root"
  cipassword = "1234"
  sshkeys    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB jenkins@control"

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
  }

  network {
    id = 0
    bridge = "vmbr0"
    model  = "virtio"
  }
}

resource "proxmox_lxc" "wireguard" {
  target_node     = "pve"
  vmid            = 126
  hostname        = "wireguard"
  ostemplate      = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.gz"
  password        = "1234"
  unprivileged    = true
  memory          = 1024
  ssh_public_keys = <<-EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB jenkins@control
  EOT

  rootfs {
    storage = "local-lvm"
    size    = "8G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "192.168.2.6/24"
    gw     = "192.168.2.1"
  }

  features {
    nesting = true
  }
}

resource "terraform_data" "media_vm_trigger" {
  depends_on = [proxmox_vm_qemu.media_vm]

  triggers_replace = {
    vm_id = proxmox_vm_qemu.media_vm.id
  }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=pve-webhook" \
      -H "Content-Type: application/json" \
      -d '{"event": "media_vm"}'
    EOT
  }
}

resource "terraform_data" "wireguard_trigger" {
  depends_on = [proxmox_lxc.wireguard]

  triggers_replace = {
    vm_id = proxmox_lxc.wireguard.id
  }

  provisioner "local-exec" {
    command = <<EOT
      sleep 30
      curl -X POST "http://192.168.2.200:8080/generic-webhook-trigger/invoke?token=pve-webhook" \
      -H "Content-Type: application/json" \
      -d '{"event": "wireguard"}'
    EOT
  }
}