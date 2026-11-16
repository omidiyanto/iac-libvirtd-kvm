terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

locals {
  # MAC tetap per VM+urutan NIC, dipakai netplan untuk mencocokkan NIC di guest
  nics = { for vm, v in var.vms : vm => [
    for i, n in v.nics : merge(n, {
      mac = coalesce(n.mac, format("52:54:00:%s", join(":", regexall("..", substr(md5("${vm}-${i}"), 0, 6)))))
    })
  ] }

  data_disks = merge([for vm, v in var.vms : {
    for i, d in v.disks : "${vm}-data${i}" => merge(d, { vm = vm, index = i })
  }]...)
}

resource "libvirt_network" "net" {
  for_each = var.networks

  name      = each.key
  autostart = each.value.autostart
  forward   = each.value.mode == "isolated" ? null : { mode = each.value.mode }
  bridge    = each.value.bridge != null ? { name = each.value.bridge } : null
  ips = each.value.mode == "bridge" ? null : [{
    address = cidrhost(each.value.cidr, 1)
    netmask = cidrnetmask(each.value.cidr)
    dhcp    = each.value.dhcp ? { ranges = [{ start = cidrhost(each.value.cidr, 100), end = cidrhost(each.value.cidr, 199) }] } : null
  }]
}

# Storage pool = folder VMs/
resource "libvirt_pool" "vms" {
  name = "iac-vms"
  type = "dir"
  target = {
    path = abspath("${path.module}/VMs")
  }
  destroy = {
    delete = false # jangan hapus folder VMs/ saat destroy
  }
}

# Copy tiap template image yang dipakai ke VMs/ sebagai base (read-only backing), satu per image
resource "libvirt_volume" "base" {
  for_each = toset([for vm in var.vms : vm.image])

  name = "base-${replace(each.key, "/\\.(img|qcow2)$/", "")}.qcow2"
  pool = libvirt_pool.vms.name
  target = {
    format = { type = "qcow2" }
  }
  create = {
    content = { url = abspath("${path.module}/image-templates/${each.key}") }
  }
}

# Disk VM: overlay qcow2 di atas base, jadi cuma simpan perubahan
resource "libvirt_volume" "disk" {
  for_each = var.vms

  name          = "${each.key}.qcow2"
  pool          = libvirt_pool.vms.name
  capacity      = each.value.disk_gb
  capacity_unit = "GiB"
  target = {
    format = { type = "qcow2" }
  }
  backing_store = {
    path   = libvirt_volume.base[each.value.image].path
    format = { type = "qcow2" }
  }
}

resource "libvirt_volume" "data" {
  for_each = local.data_disks

  name          = "${each.key}.qcow2"
  pool          = libvirt_pool.vms.name
  capacity      = each.value.size_gb
  capacity_unit = "GiB"
  target = {
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "init" {
  for_each = var.vms

  name = "${each.key}-cloudinit"
  meta_data = yamlencode({
    instance-id    = each.key
    local-hostname = each.key
  })
  user_data = each.value.user_data_file != null ? file(each.value.user_data_file) : templatefile("${path.module}/cloud-init.yaml", {
    hostname = each.key
    user     = each.value.user
    password = each.value.password
    ssh_keys = each.value.ssh_public_keys
    packages = each.value.packages
    runcmd   = each.value.runcmd
    mounts   = [for i, d in each.value.disks : { device = "/dev/disk/by-id/virtio-data${i}", path = d.mount } if d.mount != null]
  })
  network_config = yamlencode({
    version = 2
    ethernets = { for i, n in local.nics[each.key] : "nic${i}" => {
      match       = { macaddress = n.mac }
      dhcp4       = n.ip == null
      addresses   = n.ip == null ? [] : [n.ip]
      routes      = n.gateway == null ? [] : [{ to = "0.0.0.0/0", via = n.gateway }]
      nameservers = { addresses = length(n.dns) > 0 ? n.dns : n.ip != null && n.gateway != null ? [n.gateway] : [] }
    } }
  })
}

resource "libvirt_volume" "seed" {
  for_each = var.vms

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.vms.name
  create = {
    content = { url = libvirt_cloudinit_disk.init[each.key].path }
  }
}

resource "libvirt_domain" "vm" {
  for_each = var.vms

  name        = each.key
  type        = "kvm"
  memory      = each.value.memory_mb
  memory_unit = "MiB"
  vcpu        = each.value.vcpu
  running     = true
  autostart   = each.value.autostart

  cpu      = { mode = "host-passthrough" }
  features = { acpi = true }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [{ dev = "hd" }]
  }

  devices = {
    disks = concat(
      [
        {
          source  = { volume = { pool = libvirt_pool.vms.name, volume = libvirt_volume.disk[each.key].name } }
          target  = { dev = "vda", bus = "virtio" }
          driver  = { type = "qcow2" }
          io_tune = each.value.disk_io_limit_mb == null ? null : { total_bytes_sec = each.value.disk_io_limit_mb * 1048576 }
        },
        {
          device = "cdrom"
          source = { volume = { pool = libvirt_pool.vms.name, volume = libvirt_volume.seed[each.key].name } }
          target = { dev = "sda", bus = "sata" }
        },
      ],
      [for i, d in each.value.disks : {
        source  = { volume = { pool = libvirt_pool.vms.name, volume = libvirt_volume.data["${each.key}-data${i}"].name } }
        target  = { dev = "vd${substr("bcdefghijklmnop", i, 1)}", bus = "virtio" }
        driver  = { type = "qcow2" }
        serial  = "data${i}"
        io_tune = each.value.disk_io_limit_mb == null ? null : { total_bytes_sec = each.value.disk_io_limit_mb * 1048576 }
      }],
    )
    interfaces = [for i, n in local.nics[each.key] : {
      model = { type = "virtio" }
      mac   = { address = n.mac }
      source = {
        # try(): network dari var.networks -> tunggu dibuat dulu; selain itu network yang sudah ada di host
        network = n.type == "network" ? { network = try(libvirt_network.net[n.name].name, n.name) } : null
        bridge  = n.type == "bridge" ? { bridge = n.name } : null
        direct  = n.type == "macvtap" ? { dev = n.name, mode = "bridge" } : null
      }
      # IP dari DHCP lease cuma bisa dibaca untuk libvirt network
      wait_for_ip = i == 0 && n.type == "network" && n.ip == null ? { source = "lease", timeout = 300 } : null
    }]
    channels = [
      {
        source = { unix = { mode = "bind" } }
        target = { virt_io = { name = "org.qemu.guest_agent.0" } }
      },
    ]
    consoles = [
      { target = { type = "serial", port = 0 } },
    ]
    graphics = [
      { vnc = { auto_port = true, listen = "127.0.0.1" } },
    ]
  }
}

# "any" = DHCP lease libvirt, atau qemu-guest-agent (untuk bridge/static; agent siap ~1-2 menit setelah boot pertama)
data "libvirt_domain_interface_addresses" "vm" {
  for_each = var.vms

  domain = libvirt_domain.vm[each.key].name
  source = "any"
}

output "ips" {
  value = { for vm, v in var.vms : vm => distinct(concat(
    # NIC static: IP diambil dari tfvars
    [for n in v.nics : split("/", n.ip)[0] if n.ip != null],
    # NIC DHCP: IP dari lease/guest agent. NIC static dilewati supaya lease lama tidak ikut tampil
    flatten([for i in try(data.libvirt_domain_interface_addresses.vm[vm].interfaces, []) : [
      for a in i.addrs : a.addr if a.type == "ipv4" && !startswith(a.addr, "127.")
    ] if !contains([for n in local.nics[vm] : lower(n.mac) if n.ip != null], lower(try(i.hwaddr, "")))]),
  )) }
}
