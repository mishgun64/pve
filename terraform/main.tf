resource "proxmox_vm_qemu" "vm_media" {
  name        = "media"
  agent       = 0
  boot        = "order=scsi0;net0"
  pxe         = true
  target_node = "pve"            # имя Proxmox node
  vmid        = 100              # уникальный VMID
  cores       = 6
  sockets     = 1
  memory      = 2048              # MB
  scsihw      = "virtio-scsi-pci"

  # Диск
  disk {
    size        = "5G"
    type        = "disk"
    disk_file   = "local:vm-<<<vmid>>>-disk-<<<disk number>>>"
    storage     = "local"
  }

  # Сетевой интерфейс
  network {
    model     = "virtio"
    bridge    = "vmbr0"
  }

  # ISO для установки ОС
  iso         = "local:iso/ubuntu-22.04-live-server-amd64.iso"
}