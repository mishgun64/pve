resource "proxmox_vm_qemu" "vm_media" {
  name    = "media"
  target_node = "pve"            # имя Proxmox node
  vmid = 100              # уникальный VMID
  cores   = 6
  sockets = 1
  memory = 2048              # MB
  scsihw  = "virtio-scsi-pci"
  boot    = "cdn"

  # Диск
  disk {
    size    = "5G"
    type    = "scsi"
    storage = "local-lvm"
  }

  # Сетевой интерфейс
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # ISO для установки ОС
  iso = "local:iso/ubuntu-22.04-live-server-amd64.iso"
}