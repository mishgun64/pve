resource "proxmox_vm_qemu" "vm_media" {
  name        = "media"
  target_node = "pve"
  clone = "VM 9000"
  vmid = 101
  memory = 2048
  agent = 1

  cpu {
    cores = 1
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

  os_type = "cloud-init"
  ipconfig0 = "ip=192.168.1.101/24,gw=192.168.1.1"
  ciuser = "debian"
  sshkeys = file("~/.ssh/id_ed25519.pub")
}