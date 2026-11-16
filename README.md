# IaC KVM/libvirt dengan OpenTofu

Bikin network libvirt dan banyak VM KVM lokal dari satu file `terraform.tfvars`. Setiap VM bisa punya
beberapa NIC dan disk. Disk OS berupa overlay qcow2 di atas template cloud image, lalu dikonfigurasi lewat
cloud-init: user, password/SSH key, package, perintah, network, mount disk, dan qemu-guest-agent.

Provider: [`dmacvicar/libvirt`](https://registry.opentofu.org/providers/dmacvicar/libvirt) `~> 0.9.9`, koneksi `qemu:///system`.

## Struktur

```
.
├── main.tf                   # network, pool, volume, cloud-init, domain
├── variables.tf              # skema variable `networks` dan `vms`
├── cloud-init.yaml           # template user-data default
├── terraform.tfvars.example  # contoh definisi network + VM
├── image-templates/          # cloud image (qcow2), mis. resolute-server-cloudimg-amd64.img
└── VMs/                      # disk VM, base image, dan ISO cloud-init (dibuat otomatis)
```

Isi `VMs/` setelah apply:

| File | Isi |
|------|-----|
| `base-<image>.qcow2` | copy template dari `image-templates/`, satu per image, dipakai bersama oleh semua VM |
| `<vm>.qcow2` | disk OS VM (`vda`), overlay di atas base (hanya menyimpan perubahan) |
| `<vm>-data<N>.qcow2` | disk data tambahan (`vdb`, `vdc`, ...) |
| `<vm>-cloudinit.iso` | seed cloud-init (NoCloud) |

## Prasyarat

- `qemu`, `libvirt`, dan `dnsmasq` terinstal, `libvirtd` aktif, user masuk grup `libvirt`
- `opentofu`
- Folder project ada di dalam home dengan permission `700`, jadi qemu (`libvirt-qemu`) perlu izin lewat:
  ```bash
  setfacl -m u:libvirt-qemu:x $HOME
  ```
  Tanpa izin ini muncul error `Cannot access storage file ... Permission denied`.

## Pakai

```bash
cp terraform.tfvars.example terraform.tfvars   # edit sesuai kebutuhan
tofu init
tofu apply
tofu output ips
ssh ubuntu@<ip>
```

- **Tambah atau hapus VM/network:** edit `terraform.tfvars`, lalu `tofu apply`.
- **Hapus semua:** `tofu destroy`. Folder `VMs/` tetap ada, tapi semua isinya terhapus, termasuk base dan
  **disk data**. Template di `image-templates/` aman.

## Network (`networks`)

Opsional. Network `default` (NAT `192.168.122.0/24`) sudah ada di host dan tidak dikelola tofu.

```hcl
networks = {
  lab    = { mode = "isolated", cidr = "10.10.10.0/24" }
  routed = { mode = "route",    cidr = "10.20.0.0/24" }
  lan    = { mode = "bridge",   bridge = "br0" }
}
```

| Field | Default | Keterangan |
|-------|---------|------------|
| `mode` | `nat` | lihat tabel di bawah |
| `cidr` | — | wajib kecuali `bridge`. Host/gateway = `.1`, DHCP range = `.100`–`.199` |
| `dhcp` | `true` | DHCP dari libvirt (dnsmasq) |
| `bridge` | `null` | mode `bridge`: nama bridge host yang sudah ada. Mode lain: nama `virbr` (default otomatis) |
| `autostart` | `true` | network ikut start saat host boot |

| `mode` | Perilaku |
|--------|----------|
| `nat` | VM bisa ke internet lewat NAT host; dari LAN tidak terlihat. Sama seperti `default` |
| `isolated` | hanya antar-VM dan host, tanpa internet |
| `route` | tanpa NAT. VM bisa diakses dari LAN asalkan router diberi static route `<cidr> via <IP host>` |
| `bridge` | memakai bridge host yang sudah ada (mis. `br0`), jadi VM benar-benar masuk LAN |

### Bridge ke LAN dan WiFi

**NIC WiFi tidak bisa di-bridge.** Access point menolak frame dari MAC selain MAC host, dan macvtap juga
tidak jalan di WiFi. Kalau host hanya terhubung lewat WiFi, ada dua pilihan:

1. **Mode `route` (tanpa hardware tambahan).** Tambahkan static route di router:
   `10.20.0.0/24 via 192.168.1.51` (IP host). Setelah itu VM bisa diakses dari seluruh LAN.
   Catatan: IP host dari DHCP router bisa berubah, jadi buat reservasi DHCP untuk host.
2. **Pakai ethernet (port onboard atau USB-ethernet), lalu buat bridge `br0` di host.** Ini dilakukan sekali,
   di luar tofu, karena itu konfigurasi jaringan host (contoh dengan NetworkManager; ganti `enp0s31f6` dengan NIC kamu):
   ```bash
   nmcli con add type bridge ifname br0 con-name br0 ipv4.method auto stp no
   nmcli con add type bridge-slave ifname enp0s31f6 master br0
   nmcli con up br0
   ```
   Setelah itu pakai `nics = [{ type = "bridge", name = "br0" }]` di VM, atau buat network `mode = "bridge"`.

## VM (`vms`)

Key map (`web1`, `db1`) menjadi nama VM di libvirt sekaligus hostname.

```hcl
vms = {
  db1 = {
    vcpu      = 4
    memory_mb = 4096
    nics = [
      { ip = "192.168.122.200/24", gateway = "192.168.122.1" },
      { name = "lab", ip = "10.10.10.10/24" },
    ]
    disks = [
      { size_gb = 50, mount = "/var/lib/postgresql" },
      { size_gb = 10 },
    ]
    ssh_public_keys = ["ssh-ed25519 AAAA... me@host"]
  }
}
```

| Field | Default | Keterangan |
|-------|---------|------------|
| `image` | `resolute-server-cloudimg-amd64.img` | nama file di `image-templates/` (harus qcow2) |
| `vcpu` | `2` | |
| `memory_mb` | `2048` | |
| `disk_gb` | `20` | ukuran disk OS; partisi root otomatis diperbesar oleh cloud-init |
| `autostart` | `false` | VM ikut start saat host boot |
| `nics` | `[{}]` | daftar NIC, lihat di bawah. Default: 1 NIC ke `default` via DHCP |
| `disks` | `[]` | daftar disk data tambahan, lihat di bawah |
| `user` | `ubuntu` | user login |
| `password` | `null` | `null` = login password dimatikan (hanya SSH key) |
| `ssh_public_keys` | `[]` | isi public key, bukan path |
| `packages` | `[]` | package tambahan; `qemu-guest-agent` selalu diinstal |
| `runcmd` | `[]` | perintah shell yang dijalankan saat boot pertama |
| `user_data_file` | `null` | path user-data cloud-init sendiri. Menggantikan semua field cloud-init di atas, termasuk instalasi guest agent dan mount disk |

### NIC (`nics[*]`)

| Field | Default | Keterangan |
|-------|---------|------------|
| `type` | `network` | `network` (libvirt network) / `bridge` (bridge host) / `macvtap` (NIC fisik host) |
| `name` | `default` | nama libvirt network (termasuk dari `networks`) / bridge host / NIC host |
| `mac` | otomatis | default `52:54:00:xx:xx:xx`, dibentuk dari hash nama VM + urutan, jadi tetap sama antar-apply |
| `ip` | `null` (DHCP) | IP static dalam format CIDR, mis. `10.10.10.10/24` |
| `gateway` | `null` | default route. Isi di **satu NIC saja** |
| `dns` | `[]` | kosong = pakai `gateway` (kalau IP static) |

- Urutan NIC di list sama dengan urutan di guest (`enp1s0`, `enp2s0`, ...). Netplan mencocokkan NIC berdasarkan MAC.
- IP static di network yang punya DHCP sebaiknya di luar range DHCP-nya: network dari `networks` memakai
  `.100`–`.199`, sedangkan `default` memakai `.2`–`.254` (pilih `.200` ke atas).
- NIC DHCP di beberapa network NAT akan masing-masing mendapat default route. Kalau tidak diinginkan, pakai IP
  static tanpa `gateway` di NIC tambahan.

### Disk data (`disks[*]`)

| Field | Default | Keterangan |
|-------|---------|------------|
| `size_gb` | — | wajib |
| `mount` | `null` | mis. `/data`: diformat ext4 dan di-mount otomatis (fstab dengan `nofail`). `null` = disk mentah |

Disk ke-N muncul di guest sebagai `vd<b,c,d...>`, dan path tetapnya `/dev/disk/by-id/virtio-data<N>`.
Maksimal 15 disk per VM. Format hanya dilakukan saat boot pertama, dan disk yang sudah berisi filesystem
tidak diformat ulang.

## qemu-guest-agent

Selalu diinstal lewat cloud-init, dengan channel `org.qemu.guest_agent.0` di setiap VM. Dengan agent:

- `tofu output ips` bisa menampilkan IP semua NIC, termasuk NIC bridge/macvtap. Agent baru siap sekitar
  1–2 menit setelah boot pertama (menunggu `apt install`). Kalau IP-nya belum muncul, jalankan
  `tofu apply -refresh-only`.
- `virsh domifaddr <vm> --source agent`, dan `virsh shutdown` jadi lebih andal.

## cloud-init

User-data default dirender dari `cloud-init.yaml`. Untuk kebutuhan lain, tulis file sendiri:

```yaml
# cloud-init/custom1.yaml
#cloud-config
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["ssh-ed25519 AAAA..."]
packages: [qemu-guest-agent]
```

```hcl
custom1 = { user_data_file = "cloud-init/custom1.yaml" }
```

Konfigurasi network (`nics`) tetap dikirim lewat `network-config`, jadi tetap berlaku saat memakai `user_data_file`.

cloud-init hanya jalan sekali, saat boot pertama. Kalau user-data VM yang sudah ada diubah, VM tidak ikut
berubah. Untuk menerapkannya, buat ulang VM-nya (disk OS di-reset, disk data tetap):

```bash
tofu apply -replace='libvirt_volume.disk["db1"]' -replace='libvirt_domain.vm["db1"]'
```

## Operasional

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system   # supaya virsh melihat VM yang sama
virsh list --all
virsh net-list --all
virsh console db1        # serial console, keluar dengan Ctrl+]
virsh domifaddr db1 --source agent
virt-manager             # GUI; display VNC hanya listen di 127.0.0.1
```

## Keamanan

- `password` tersimpan sebagai teks biasa di `terraform.tfvars`, `terraform.tfstate`, dan ISO cloud-init.
  Untuk apa pun di luar lab, pakai SSH key dan biarkan `password = null`.
- `.gitignore` sudah mengecualikan `terraform.tfvars`, state, dan isi `VMs/`.
