resource "proxmox_vm_qemu" "vm_media" {
  name        = "media"
  target_node = "pve"
  clone = "debian-cloudinit-template"
  vmid = 101
  memory = 2048
  agent = 1
  scsihw = "virtio-scsi-single"
  boot = "order=scsi0"

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }
  # Диск
  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = "local-lvm"
    size    = "5G"
  }

  # Сетевой интерфейс
  network {
    id        = 0
    model     = "virtio"
    bridge    = "vmbr0"
  }

  serial {
    id   = 0
    type = "socket"
  }

  vga {
    type = "serial0"
  }

  os_type = "cloud-init"
  ipconfig0 = "ip=192.168.1.101/24,gw=192.168.1.1"
  ciuser = "debian"
  sshkeys = file("~/.ssh/id_ed25519.pub")

}