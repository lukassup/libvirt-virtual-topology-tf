terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.1"
    }
    external = {
     source = "hashicorp/external"
     version = "~> 2.3.1"
    }
  }
}


variable "topology_file" {
  type = string
  default = "topology.dot"
}
variable "topology_id" {
  type    = number
  default = 1
}

variable "libvirt_local" {
  type    = bool
  default = false
}

variable "libvirt_host" {
  type    = string
  default = null
}

variable "image_url" {
  type    = string
  default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
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
  tunnel_cidr = cidrsubnet("127.1.0.0/16", 16, var.topology_id)
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
  bridge    = "virbr${100 + var.topology_id}"
  mode      = "nat"
  addresses = [local.network_cidr]
  domain    = "kvm.local"
  autostart = true
  dhcp {
    enabled = true
  }
  dns {
    enabled    = true
    local_only = false
  }
}

resource "libvirt_volume" "base" {
  name   = "debian12-latest.qcow2"
  source = var.image_url
}

resource "libvirt_volume" "vol" {
  for_each       = { for host, i in local.hosts : host => i + 1 }
  name           = format("%02d-%s.qcow2", var.topology_id, each.key)
  base_volume_id = libvirt_volume.base.id
}

resource "libvirt_cloudinit_disk" "cloud_init" {
  for_each       = { for host, i in local.hosts : host => i + 1 }
  name      = format("%02d-%s-cloudinit.iso", var.topology_id, each.key)
  meta_data = templatefile("${path.module}/cloud-init/meta-data.yml", {})
  user_data = templatefile("${path.module}/cloud-init/user-data.yml", {
    user               = var.user
    ssh_authorized_key = trimspace(file(pathexpand("~/.ssh/id_rsa.pub")))
    routing            = strcontains(each.key, "oob-") ? false : true
    # spines should have same BGP ASN
    bgp_as    = strcontains(each.key, "spine") ? var.bgp_asn : var.bgp_asn + each.value
    router_id = cidrhost(var.loopback_cidr, each.value)
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.yml", {
    mgmt_mac = format("52:54:00:00:%02X:%02X", var.topology_id, each.value)
    routing  = strcontains(each.key, "oob-") ? false : true
  })
}

resource "libvirt_domain" "domain" {
  for_each       = { for host, i in local.hosts : host => i + 1 }
  name      = format("%02d-%s", var.topology_id, each.key)
  vcpu      = local.cpu[each.key]
  memory    = local.memory[each.key]
  autostart = true
  cloudinit = libvirt_cloudinit_disk.cloud_init[each.key].id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.vol[each.key].id
  }

  network_interface {
    network_id = libvirt_network.mgmt_network.id
    hostname   = each.key
    # NOTE: first subnet IP is reserved for libvirt network bridge
    addresses = [cidrhost(local.network_cidr, each.value + 1)]
    # NOTE: MAC address must start from 01
    mac            = format("52:54:00:00:%02X:%02X", var.topology_id, each.value)
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  video {
    type = "none"
  }

  xml {
    xslt = (fileexists("${path.module}/links/${each.key}.xsl")
     ? templatefile("${path.module}/links/${each.key}.xsl", {topology_id = var.topology_id})
     : null)
  }
}

locals {
  ssh_cmd = format("ssh%s", !var.libvirt_local ? " -J ${var.libvirt_host}" : "")
}

output "ssh_cmd" {
  value = { for name, domain in libvirt_domain.domain :
  name => format("%s %s@%s", local.ssh_cmd, var.user, domain.network_interface[0].addresses[0]) }
}
