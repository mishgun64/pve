resource "proxmox_vm_qemu" "vm_media" {
  name        = "media"
  agent       = 0
  boot        = "order=scsi0;net0"
  pxe         = true
  target_node = "pve"            # имя Proxmox node
  vmid        = 100              # уникальный VMID
  memory      = 2048              # MB
  scsihw      = "virtio-scsi-pci"

  cpu {
    cores = 6
  }
  # Диск
  disk {
    size        = "5G"
    type        = "disk"
    disk_file   = "local:vm-<<<vmid>>>-disk-<<<disk number>>>"
    storage     = "local"
    slot        = "scsi0"
  }

  # Сетевой интерфейс
  network {
    id        = 0
    model     = "virtio"
    bridge    = "vmbr0"
  }

}