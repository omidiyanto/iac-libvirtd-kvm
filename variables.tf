variable "networks" {
  description = "Network libvirt yang dikelola tofu. Key = nama network."
  type = map(object({
    mode      = optional(string, "nat") # nat | isolated | route | bridge
    cidr      = optional(string)        # subnet, mis. 10.10.10.0/24 (wajib kecuali mode bridge). Host = .1, DHCP = .100-.199
    dhcp      = optional(bool, true)
    bridge    = optional(string) # mode bridge: nama bridge host yang sudah ada (mis. br0). Mode lain: nama virbr (opsional)
    autostart = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for n in var.networks : contains(["nat", "isolated", "route", "bridge"], n.mode)])
    error_message = "networks.*.mode harus nat, isolated, route, atau bridge."
  }
  validation {
    condition     = alltrue([for n in var.networks : n.mode == "bridge" ? n.bridge != null : can(cidrhost(n.cidr, 199))])
    error_message = "Mode bridge wajib isi bridge; mode lain wajib isi cidr yang muat .1-.199 (mis. 10.10.10.0/24)."
  }
}

variable "vms" {
  description = "Daftar VM. Key = nama VM (dipakai juga sebagai hostname)."
  type = map(object({
    image     = optional(string, "resolute-server-cloudimg-amd64.img") # file di image-templates/
    vcpu      = optional(number, 2)
    memory_mb = optional(number, 2048)
    disk_gb   = optional(number, 20) # disk OS (vda)
    # Batas throughput total (baca+tulis) per disk VM, MiB/s. null = tanpa limit
    disk_io_limit_mb = optional(number)
    autostart        = optional(bool, false)

    # NIC, urutan = urutan di VM. Default: 1 NIC ke network "default" via DHCP
    nics = optional(list(object({
      type    = optional(string, "network") # network | bridge | macvtap
      name    = optional(string, "default") # nama libvirt network (termasuk dari var.networks) / bridge host / NIC host
      mac     = optional(string)            # null = dibuat otomatis (tetap per VM+urutan)
      ip      = optional(string)            # CIDR, mis. 192.168.122.10/24. null = DHCP
      gateway = optional(string)            # isi di satu NIC saja untuk default route
      dns     = optional(list(string), [])  # kosong = pakai gateway
    })), [{}])

    # Disk data tambahan (vdb, vdc, ...). Muncul di guest sebagai /dev/disk/by-id/virtio-data0, -data1, ...
    disks = optional(list(object({
      size_gb = number
      mount   = optional(string) # mis. /data -> diformat ext4 & di-mount otomatis. null = disk mentah
    })), [])

    # cloud-init
    user            = optional(string, "ubuntu")
    password        = optional(string) # null = login password dimatikan
    ssh_public_keys = optional(list(string), [])
    packages        = optional(list(string), []) # qemu-guest-agent selalu diinstal
    runcmd          = optional(list(string), [])
    user_data_file  = optional(string) # path user-data sendiri, menggantikan semua opsi cloud-init di atas
  }))

  validation {
    condition     = alltrue(flatten([for v in var.vms : [for n in v.nics : contains(["network", "bridge", "macvtap"], n.type)]]))
    error_message = "nics.*.type harus network, bridge, atau macvtap."
  }
  validation {
    condition     = alltrue(flatten([for v in var.vms : [for n in v.nics : n.ip == null || can(cidrhost(n.ip, 0))]]))
    error_message = "nics.*.ip harus format CIDR, mis. 192.168.122.10/24."
  }
  validation {
    condition     = alltrue([for v in var.vms : length(v.nics) >= 1 && length(v.disks) <= 15])
    error_message = "Minimal 1 NIC dan maksimal 15 disk data per VM."
  }
}
