##
#  topology.dot file parsing
#

data "local_file" "topology" {
  filename = "${path.module}/${var.topology_file}"
}

locals {
  # topology nodes
  topology = jsondecode(data.local_file.topology.content)
  hosts    = { for o in local.topology.objects : (o.name) => o._gvid }
  hosts_   = { for o in local.topology.objects : (o._gvid) => o.name }
  host_params = { for o in local.topology.objects :
    (o.name) => {
      id = o._gvid
      # default resources
      cpu    = tonumber(lookup(o, "cpu", 1))
      memory = tonumber(lookup(o, "memory", 512))
    }
  }

  # topology links
  links = merge(
    # forward links
    { for o in local.topology.edges : (local.hosts_[o.head]) => {
      link_id  = o._gvid
      src_id   = o.head
      dst_id   = o.tail
      src_port = o.headport
      dst_port = o.tailport
      dst_host = local.hosts_[o.tail]
    }... },
    # reverse links
    { for o in local.topology.edges : (local.hosts_[o.tail]) => {
      link_id  = o._gvid
      src_id   = o.tail
      dst_id   = o.head
      src_port = o.tailport
      dst_port = o.headport
      dst_host = local.hosts_[o.head]
    }... }
  )
}
