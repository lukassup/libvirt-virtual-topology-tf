terraform {
  required_version = ">= 1, <2"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.7"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9.0"
    }
  }
}

variable "topology_file" {
  type    = string
  default = "topology.dot.json"
}

variable "topology_id" {
  type    = number
  default = 1
}

variable "libvirt_local" {
  type    = bool
  default = true
}

variable "libvirt_host" {
  type    = string
  default = "localhost"
}

variable "image_url" {
  type    = string
  default = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "user" {
  type    = string
  default = "debian"
}

variable "topology_network_prefix" {
  type    = string
  default = "172.31.0.0/16"
}

locals {
  network_cidr = cidrsubnet(var.topology_network_prefix, 8, var.topology_id)
  tunnel_cidr  = cidrsubnet("127.1.0.0/16", 8, var.topology_id)
}

variable "loopback_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "bgp_asn" {
  type    = number
  default = 64512
}

provider "libvirt" {
  uri = var.libvirt_local ? "qemu:///system" : "qemu+ssh://${var.libvirt_host}/system"
}

resource "libvirt_network" "mgmt_network" {
  name      = format("%02d-mgmt-network", var.topology_id)
  autostart = true
  bridge = {
    name = "virbr${100 + var.topology_id}"
  }
  forward = { mode = "nat" }
  domain = {
    name       = "kvm.local"
    local_only = "yes"
  }
  ips = [{
    address = cidrhost(local.network_cidr, 1)
    dhcp = {
      ranges = [{
        start = cidrhost(local.network_cidr, 2)
        end   = cidrhost(local.network_cidr, -2)
      }]
      hosts = [for host, i in local.hosts : {
        name = format("%02d-%s", var.topology_id, host)
        mac  = format("52:54:00:00:%02X:%02X", var.topology_id, i + 1)
        ip   = cidrhost(local.network_cidr, 2 + i)
      }]
    }
  }]
}

resource "libvirt_volume" "base" {
  name     = "debian13-latest.qcow2"
  pool     = "default"
  capacity = 20 * pow(2, 10)
  target = {
    format = { type = "qcow2" }
  }
  create = {
    content = { url = var.image_url }
  }
}

resource "libvirt_volume" "vol" {
  for_each = { for host, i in local.hosts : host => i + 1 }
  pool     = "default"
  name     = format("%02d-%s.qcow2", var.topology_id, each.key)
  capacity = pow(10, 9) * 20
  target = {
    format = { type = "qcow2" }
  }
  backing_store = {
    path   = libvirt_volume.base.id
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "cloud_init" {
  for_each  = { for host, i in local.hosts : host => i + 1 }
  name      = format("%02d-%s-cloudinit.iso", var.topology_id, each.key)
  meta_data = templatefile("${path.module}/cloud-init/meta-data.yml", {})
  user_data = templatefile("${path.module}/cloud-init/user-data.yml", {
    user               = var.user
    ssh_authorized_key = trimspace(file(pathexpand("~/.ssh/id_ed25519.pub")))
    switch_ports = { for interface_id, link in lookup(local.links, each.key, []) :
      "swp${interface_id}" => format("52:54:00:%02X:%02X:%02X", var.topology_id, each.value, interface_id + 1)
    }
    # spines should have same BGP ASN
    bgp_as    = strcontains(each.key, "spine") ? var.bgp_asn : var.bgp_asn + each.value
    router_id = cidrhost(var.loopback_cidr, each.value)
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.yml", {
    mgmt_mac = format("52:54:00:00:%02X:%02X", var.topology_id, each.value)
    switch_ports = { for interface_id, link in lookup(local.links, each.key, []) :
      "swp${interface_id}" => format("52:54:00:%02X:%02X:%02X", var.topology_id, each.value, interface_id + 1)
    }
    router_id    = cidrhost(var.loopback_cidr, each.value)
    bridge_ports = strcontains(each.key, "leaf")
  })
}

resource "libvirt_volume" "cloud_init" {
  for_each = { for host, i in local.hosts : host => i + 1 }
  name     = format("%02d-%s-cloudinit.iso", var.topology_id, each.key)
  pool     = "default"
  create = {
    content = {
      url = libvirt_cloudinit_disk.cloud_init[each.key].path
    }
  }
}

resource "libvirt_domain" "this" {
  for_each  = { for host, i in local.hosts : host => i + 1 }
  name      = format("%02d-%s", var.topology_id, each.key)
  autostart = true
  running   = true
  type      = "kvm"
  vcpu      = local.host_params[each.key].cpu
  memory    = pow(2, 10) * local.host_params[each.key].memory

  features = { acpi = true }

  cpu = { mode = "host-passthrough" }

  os = {
    type_arch       = "x86_64"
    type            = "hvm"
    type_machine    = "q35"
    firmware        = "efi"
    loader          = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
    loader_readonly = "yes"
    nv_ram = {
      template = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
      nv_ram   = format("/var/lib/libvirt/qemu/nvram/%02d-%s.fd", var.topology_id, each.key)
    }
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = "default"
            volume = libvirt_volume.vol[each.key].name
          }
        }
        target = {
          bus = "virtio"
          dev = "vda"
        }
        driver = { type = "qcow2" }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.cloud_init[each.key].pool
            volume = libvirt_volume.cloud_init[each.key].name
          }
        }
        target = {
          bus = "sata"
          dev = "sda"
        }
      }
    ],
    interfaces = concat([
      {
        type        = "network"
        wait_for_ip = {}
        source = {
          network = {
            network = libvirt_network.mgmt_network.name
          }
        }
        mac = {
          address = format("52:54:00:00:%02X:%02X", var.topology_id, each.value)
          type    = "static"
          check   = "yes"
        }
        model = { type = "virtio" }
      }
      ], [
      for interface_id, link in lookup(local.links, each.key, []) :
      {
        source = {
          udp = {
            address = cidrhost(local.tunnel_cidr, link.dst_id)
            port    = 10000 + link.link_id
            local = {
              address = cidrhost(local.tunnel_cidr, link.src_id)
              port    = 10000 + link.link_id
            }
          }
        }
        mac = {
          address = format("52:54:00:%02X:%02X:%02X", var.topology_id, each.value, interface_id + 1)
          type    = "static"
          check   = "yes"
        }
        model = { type = "virtio" }
      }
    ])
    consoles = [{
      source = {
        target = { type = "virtio" }
      }
    }],
  }
}

data "libvirt_domain_interface_addresses" "this" {
  for_each = libvirt_domain.this
  domain   = each.value.uuid
}

locals {
  ssh_cmd = format("ssh%s", !var.libvirt_local ? " -J ${var.libvirt_host}" : "")
}

output "ssh_cmd" {
  value = { for name, domain in data.libvirt_domain_interface_addresses.this :
    name => format("%s %s@%s", local.ssh_cmd, var.user, domain.interfaces[0].addrs[0].addr)
  }
}
