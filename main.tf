terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.1"
    }
  }
}

variable "image_url" {
  type    = string
  default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
}
variable "vcpu" {
  type    = number
  default = 1
}

variable "memory" {
  type    = number
  default = 512
}

variable "user" {
  type    = string
  default = "debian"
}

variable "network_cidr" {
  type    = string
  default = "172.31.255.0/24"
}

variable "loopback_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "bgp_asn" {
  type    = number
  default = 64512
}

variable "vms" {
  type = list(string)
  default = [
    "oob-mgmt-server",
    "leaf01",
    "leaf02",
    "spine01",
    "spine02",
  ]
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_network" "mgmt_network" {
  name      = "mgmt-net01"
  bridge    = "virbr100"
  mode      = "nat"
  addresses = [var.network_cidr]
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
  for_each       = { for index, vm in var.vms : vm => index + 1 }
  name           = "${each.key}.qcow2"
  base_volume_id = libvirt_volume.base.id
}

resource "libvirt_cloudinit_disk" "cloud_init" {
  for_each  = { for index, vm in var.vms : vm => index + 1 }
  name      = "${each.key}-cloudinit.iso"
  meta_data = templatefile("${path.module}/cloud-init/meta-data.yml", {})
  user_data = templatefile("${path.module}/cloud-init/user-data.yml", {
    user               = var.user
    ssh_authorized_key = trimspace(file(pathexpand("~/.ssh/id_rsa.pub")))
    network            = strcontains(each.key, "oob-") ? false : true
    # spines should have same BGP ASN
    bgp_as    = strcontains(each.key, "spine") ? var.bgp_asn : var.bgp_asn + each.value
    router_id = cidrhost(var.loopback_cidr, each.value)
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.yml", {
    mgmt_mac = format("52:54:00:00:00:%02X", each.value)
    network  = strcontains(each.key, "oob-") ? false : true
  })
}

resource "libvirt_domain" "terraform_test" {
  for_each  = { for index, vm in var.vms : vm => index + 1 }
  name      = each.key
  vcpu      = var.vcpu
  memory    = var.memory
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
    addresses = [cidrhost(var.network_cidr, each.value + 1)]
    # NOTE: MAC address must start from 01
    mac            = format("52:54:00:00:00:%02X", each.value)
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
    xslt = fileexists("${path.module}/links/${each.key}.xsl") ? file("${path.module}/links/${each.key}.xsl") : null
  }
}

output "ssh_cmd" {
  value = { for name, domain in libvirt_domain.terraform_test :
  name => format("ssh %s@%s", var.user, domain.network_interface[0].addresses[0]) }
}
