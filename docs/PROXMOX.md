# A Proxmox VM for Basketball Scout

This page sets up an Ubuntu Server 24.04 LTS virtual machine on Proxmox VE 8 or 9 for
developing or running Basketball Scout. With the default `SCOUT_PROCESSOR=modal` the
GPU work runs on Modal, so **the VM needs no GPU**. GPU passthrough is only for
running the computer vision on your own card (`SCOUT_PROCESSOR=local`), described at
the end.

Use a VM rather than an LXC container: the systemd sandboxing in the service units
needs namespaces (an unprivileged container needs `nesting=1`), and GPU passthrough is
simpler with a VM.

## The VM at a glance

| Setting | Value | Why |
|---|---|---|
| Machine | `q35` | Modern PCIe chipset. Required for PCIe GPU passthrough (`pcie=1`). |
| Firmware | OVMF (UEFI) with an EFI disk | UEFI boot, Secure Boot with pre-enrolled keys; needed for passthrough of modern GPUs. |
| CPU type | `host`, 1 socket, 8 cores | Passes the real CPU's features (AVX, AVX2, FMA) to NumPy and PyTorch. |
| Memory | 32 GB (32768 MiB), ballooning off | Analysing a full game holds a lot of tracking data in memory. |
| Disk | 200 GB on VirtIO SCSI single, `iothread=1,discard=on,ssd=1,cache=none` | Film is big; TRIM gives space back when games are deleted. |
| Network | VirtIO, firewall on | Fastest virtual NIC; multi-GB uploads. |
| Guest agent | on | Clean shutdowns, IP shown in the GUI, consistent backups. |
| OS | Ubuntu Server 24.04 LTS | What `scripts/install.sh` is tested on. |

### Why these settings

- **q35 instead of i440fx.** i440fx is the old default PCI chipset. q35 gives the guest
  a PCIe topology, which `hostpci0: ...,pcie=1` needs.
- **OVMF and the EFI disk.** The EFI disk (`efidisk0`) stores the UEFI variables: boot
  entries and Secure Boot keys. `efitype=4m` is the current format.
  `pre-enrolled-keys=1` enrolls the standard Microsoft keys, so Secure Boot is on and
  Ubuntu boots through its signed shim as usual. If you later load NVIDIA modules
  built by DKMS (GPU passthrough), Secure Boot asks you to enroll a MOK key on the next
  boot; Ubuntu's prebuilt, signed driver packages avoid that. To run without Secure Boot,
  use `pre-enrolled-keys=0`.
- **CPU type `host`.** Proxmox's default CPU types (such as `x86-64-v2-AES`) hide
  AVX and AVX2. NumPy and PyTorch choose their fast code paths at run time from the CPU
  flags, and some libraries need AVX outright, so `host` makes the analysis noticeably
  faster. The trade-off: a VM with `host` can only live-migrate to a node with the same
  CPU. That does not matter on a single node; in a cluster with mixed CPUs, pick the
  newest level every node supports instead, e.g. `x86-64-v3` (includes AVX2).
- **8 cores.** The web app is light; the worker's analysis step (NumPy) and file copies
  use the CPU, and several games can be analysed at once. The GPU part runs on Modal.
- **32 GB and ballooning.** With ballooning on, Proxmox can take memory back from the
  guest when the host is short, which can hit the worker in the middle of an analysis.
  Use a fixed size (`--balloon 0`); passthrough requires that anyway, because a
  passed-through device needs all guest memory pinned. On a tight host without
  passthrough you can allow ballooning down to a floor, e.g. `--balloon 16384`.
- **Disk options.** *VirtIO SCSI single* gives each disk its own controller, so
  `iothread=1` can run its I/O in a dedicated thread. `discard=on` passes TRIM to thin
  storage (LVM-thin, ZFS, Ceph); Ubuntu trims weekly (`fstrim.timer`), so deleted film
  frees space on the host. `ssd=1` tells the guest it is on an SSD. `cache=none` is the
  safe Proxmox default (no host page cache; `writeback` is faster but riskier on power
  loss).
- **VirtIO NIC.** The paravirtualized NIC is the fastest; `firewall=1` lets the Proxmox
  firewall filter the VM's traffic if you turn it on.
- **QEMU guest agent.** Lets Proxmox shut the VM down cleanly, show its IP address, and
  freeze the filesystem during snapshot backups so they are consistent.

## Create the VM from the command line

1. Download the current Ubuntu Server 24.04 LTS ISO from
   <https://ubuntu.com/download/server> and put it on an ISO storage (web UI: *local >
   ISO Images > Upload*, or `wget` it into `/var/lib/vz/template/iso/` on the host).
2. On the Proxmox host, as root (adjust the three variables):

```bash
VMID=9100
STORAGE=local-lvm                                      # local-lvm, local-zfs, ceph...
ISO=local:iso/ubuntu-24.04.3-live-server-amd64.iso     # the file you uploaded
qm create $VMID \
  --name basketball-scout \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=1 \
  --cpu host \
  --sockets 1 --cores 8 \
  --memory 32768 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 $STORAGE:200,iothread=1,discard=on,ssd=1,cache=none \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --ide2 $ISO,media=cdrom \
  --boot 'order=scsi0;ide2' \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot 1
qm start $VMID
```

`$STORAGE:1` for the EFI disk is the usual syntax; Proxmox sizes the EFI disk itself.
`$STORAGE:200` creates the 200 GB system disk. Open the VM's *Console* in the web UI to
run the installer.

The same in the web UI (*Create VM*): **OS** the ISO, type Linux; **System** machine
`q35`, BIOS `OVMF (UEFI)`, add EFI disk with *Pre-Enroll keys*, SCSI controller *VirtIO
SCSI single*, *Qemu Agent* ticked; **Disks** 200 GB with *Discard*, *IO thread* and
*SSD emulation* (under Advanced), cache *Default (No cache)*; **CPU** 1 socket, 8 cores,
type `host`; **Memory** 32768 MiB with *Ballooning Device* unticked; **Network** bridge
`vmbr0`, model *VirtIO*, *Firewall* ticked.

## Install Ubuntu Server 24.04

1. Boot and choose *Try or Install Ubuntu Server*; pick language and keyboard.
2. Installation type: **Ubuntu Server** (not the minimized one).
3. Network: DHCP is fine for now (set a reservation later, see
   [Networking](#networking)), or edit the interface for a static IPv4 address.
4. Proxy: enter the school's proxy if outbound traffic needs one. Keep the default
   mirror.
5. Storage: *Use an entire disk* with *Set up this disk as an LVM group*. **Check the
   summary:** the guided layout often gives the root volume only part of the disk (about
   100 GB of 200 GB). Select `ubuntu-lv`, choose *Edit* and set the size to the maximum.
   If you missed it, fix it after the install with
   `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`.
6. Profile: your name, server name `basketball-scout`, and an admin username. **Do not
   use `scout`**: `install.sh` creates that as the service user.
7. Skip Ubuntu Pro. Tick **Install OpenSSH server** (optionally import your SSH key from
   GitHub). No featured snaps.
8. Reboot when asked, then detach the ISO on the host: `qm set $VMID --ide2 none,media=cdrom`.

### Alternative: cloud-init image (no installer)

On the Proxmox host. The `local` storage must allow the *Snippets* content type for the
vendor file (`pvesm set local --content ...` replaces the whole list, so include what
you already use):

```bash
VMID=9100
STORAGE=local-lvm
wget -O /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
pvesm set local --content iso,vztmpl,backup,snippets
cat > /var/lib/vz/snippets/basketball-scout-vendor.yaml <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages: [qemu-guest-agent, git]
runcmd:
  - systemctl start qemu-guest-agent
EOF
qm create $VMID --name basketball-scout --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=1 --cpu host --sockets 1 --cores 8 \
  --memory 32768 --balloon 0 --scsihw virtio-scsi-single \
  --scsi0 $STORAGE:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,iothread=1,discard=on,ssd=1,cache=none \
  --net0 virtio,bridge=vmbr0,firewall=1 --agent enabled=1,fstrim_cloned_disks=1 \
  --ide2 $STORAGE:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 --onboot 1
qm disk resize $VMID scsi0 200G
qm set $VMID --ciuser itadmin --sshkeys ~/.ssh/authorized_keys --ipconfig0 ip=dhcp \
  --cicustom "vendor=local:snippets/basketball-scout-vendor.yaml"
qm start $VMID
```

Log in with `ssh itadmin@<vm address>` (the address shows on the VM's *Summary* page once
the guest agent runs). The cloud image grows its filesystem to the full 200 GB on first
boot.

## After the install

Inside the VM:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y qemu-guest-agent && sudo systemctl start qemu-guest-agent
sudo timedatectl set-timezone America/Chicago          # your time zone
cat /etc/apt/apt.conf.d/20auto-upgrades                # unattended-upgrades: on by default
sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw enable   # 8000/tcp without nginx
sudo reboot
```

Ubuntu Server installs `unattended-upgrades` and applies security updates by default;
the file above should contain `APT::Periodic::Unattended-Upgrade "1";` (if not:
`sudo dpkg-reconfigure -plow unattended-upgrades`).

Then install Basketball Scout (see the [README](../README.md#install-on-an-ubuntu-server)):

```bash
sudo apt install -y git
git clone https://github.com/Marquette-Catholic-High-School/basketball-scout.git
cd basketball-scout
sudo scripts/install.sh --with-nginx
```

## Storage sizing

| Per 60-minute game | Size | Notes |
|---|---|---|
| Original film, 1080p | 2-6 GB | 720p is roughly half |
| Annotated video (720p) | about 0.5-1.5 GB | `SCOUT_RENDER_ANNOTATED_VIDEO=false` skips it |
| Tracking data and analysis JSON | tens of MB | |
| Database | a few MB in total | |

Ubuntu, the app and its Python environment take about 15-20 GB, so a 200 GB disk holds
roughly 25-70 games depending on the film. Keep 20 GB or so free for uploads in
progress. **Retention tip:** at the end of each season export what you want to keep
(FastScout, the report's `.md`, `analysis.json`; all small) and delete the old games
on the Games page, which removes their film. For a lot of film, add a second disk just
for the data and mount it at `/var/lib/basketball-scout`:

```bash
qm set $VMID --scsi1 $STORAGE:500,iothread=1,discard=on,ssd=1,cache=none
```

(then partition, format and mount it in the guest before running `install.sh`, or
stop the services and move the data as described in [DEPLOYMENT.md](DEPLOYMENT.md)).

## Backups

- **Whole-VM backups with vzdump** (simplest): *Datacenter > Backup > Add*, mode
  **Snapshot**, compression ZSTD, a nightly schedule and a retention such as keep-daily 7,
  keep-weekly 4. With the guest agent, snapshot mode briefly freezes the filesystem, so
  the SQLite database is consistent. One-off from the shell:
  `vzdump $VMID --mode snapshot --compress zstd --storage <backup storage>`. A Proxmox
  Backup Server deduplicates (film rarely changes, so nightly backups are incremental)
  and can encrypt on the client; the backups contain film of students, so encrypt them.
- **Only the data**, from inside the VM: an online copy of the database with
  `sqlite3 /var/lib/basketball-scout/scout.db ".backup '/backup/scout.db'"`, plus `rsync`
  of `/var/lib/basketball-scout/` and a copy of `/opt/basketball-scout/.env`. A complete
  script and the restore steps are in [DEPLOYMENT.md](DEPLOYMENT.md#backups).

## Snapshots before updates

Snapshots need storage that supports them (LVM-thin, ZFS, Ceph, qcow2; not plain LVM).

```bash
qm snapshot $VMID before-update-$(date +%Y%m%d) --description "before scripts/update.sh"
# in the VM:
sudo /opt/basketball-scout/scripts/update.sh
# all good: delete the snapshot (snapshots grow and slow the disk over time)
qm delsnapshot $VMID before-update-20261028
# it went wrong: roll back (this also loses games added since the snapshot)
qm rollback $VMID before-update-20261028
```

A VM with a passed-through GPU cannot save its RAM state in a snapshot; take the
default disk-only snapshot or shut the VM down first.

## GPU passthrough (optional, `SCOUT_PROCESSOR=local` only)

> **Not needed when you use Modal** (the default). Only do this to run the computer
> vision on your own NVIDIA card instead of renting one.

You need an NVIDIA GPU with plenty of memory (the Modal default, an A10G, has 24 GB;
smaller cards are more likely to fail with `GPU_OOM`), a CPU and board with an IOMMU
(Intel VT-d or AMD-Vi), and the GPU in its own IOMMU group. Give the VM more RAM too:
the same work gets 32 GB on Modal by itself, so plan 48-64 GB for the VM.

On the Proxmox host:

1. **Firmware:** enable VT-d (Intel) or AMD-Vi / IOMMU (AMD), and *Above 4G decoding*
   if the board has it.
2. **Kernel command line.** GRUB (most installs): in `/etc/default/grub` set
   `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"` (AMD:
   `quiet amd_iommu=on iommu=pt`), then `update-grub`. systemd-boot (ZFS root on UEFI):
   add the same words to `/etc/kernel/cmdline`, then `proxmox-boot-tool refresh`.
   Recent Proxmox kernels turn the IOMMU on by default; adding the option does no harm.
3. **VFIO modules:** add them to `/etc/modules`:

   ```bash
   printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
   ```

4. **Keep the host's drivers off the card.** Find the card's IDs with
   `lspci -nn | grep -i nvidia` (one ID per function, like `10de:XXXX`), then:

   ```bash
   echo "options vfio-pci ids=10de:XXXX,10de:YYYY" > /etc/modprobe.d/vfio.conf
   echo "softdep nouveau pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
   printf 'blacklist nouveau\nblacklist nvidiafb\n' > /etc/modprobe.d/blacklist-gpu.conf
   update-initramfs -u -k all
   reboot
   ```

   Check: `dmesg | grep -e DMAR -e IOMMU` shows the IOMMU is on, and
   `lspci -nnk -s 01:00` shows `Kernel driver in use: vfio-pci`.
5. **Give the GPU to the VM** (it must be `q35` + OVMF with ballooning off, as above).
   Use the card's address from `lspci`; leaving off `.0` passes all its functions:

   ```bash
   qm set $VMID --hostpci0 0000:01:00,pcie=1
   ```

In the VM:

```bash
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers list --gpgpu                     # see which server drivers exist
sudo ubuntu-drivers install --gpgpu nvidia:580-server
sudo apt install -y nvidia-utils-580-server
sudo reboot
nvidia-smi                                           # shows the GPU and the driver version
```

The GPU pipeline's PyTorch is built for CUDA 13.0, which needs NVIDIA driver **580 or
newer**; pick a newer `-server` driver if `ubuntu-drivers` lists one. With Secure Boot
on, Ubuntu's signed driver packages load directly; a DKMS-built module asks you to
enroll a MOK key on the next boot.

Then install with the local processor:

```bash
sudo scripts/install.sh --processor local
```

That also installs `modal_app/requirements-gpu.txt` (CUDA builds of PyTorch, several GB)
and OpenHoopVision with its model weights in `/opt/openhoopvision`, and makes the NVIDIA
kernel modules (`nvidia`, `nvidia_uvm`) load at boot: the worker runs in a systemd
sandbox that cannot load them on first use. If CUDA still reports no device under the
service, check `ls /dev/nvidia*` (it should list `/dev/nvidia-uvm`) and reboot once.
Local runs go one at a time, and a film being processed is lost if the worker restarts
(retry it), so do not update in the middle of a run.

## Networking

- **Fixed address.** Best: a DHCP reservation for the VM's MAC address
  (`qm config $VMID | grep net0` shows it) plus a DNS name such as
  `scout.myschool.local`. Or a static address in the guest, in
  `/etc/netplan/50-cloud-init.yaml` (the installer may name it `00-installer-config.yaml`;
  the interface is usually `ens18`), then `sudo netplan apply`:

  ```yaml
  network:
    version: 2
    ethernets:
      ens18:
        addresses: [10.20.30.40/24]
        routes:
          - to: default
            via: 10.20.30.1
        nameservers:
          addresses: [10.20.30.1]
  ```

- **Firewall.** `ufw` in the guest (above): SSH plus 80 and 443 with nginx, or 8000
  without it. Optionally also the Proxmox firewall (*VM > Firewall*, enable and allow
  those ports from the school's subnets only).
- **Reverse proxy.** `install.sh --with-nginx` sets up nginx in the VM. If the school
  already has a reverse proxy, point it at the VM and copy the settings that matter from
  `deploy/nginx/basketball-scout.conf`: `client_max_body_size 64m`,
  `proxy_request_buffering off`, long timeouts, and Range headers passed through.
- **Tailscale** (remote access without opening ports): in the VM run
  `curl -fsSL https://tailscale.com/install.sh | sh`, `sudo tailscale up`, then
  `sudo tailscale serve --bg 8000`. Coaches on your tailnet open
  `https://basketball-scout.<tailnet>.ts.net` with a real certificate (turn on MagicDNS
  and HTTPS in the Tailscale admin console). Nobody else can reach it.
- **Outbound access.** The VM needs HTTPS to github.com, pypi.org and
  files.pythonhosted.org (install and updates), modal.com (film upload and GPU jobs) and
  api.anthropic.com (reports). A firewall that inspects TLS must let modal.com through
  unmodified.
