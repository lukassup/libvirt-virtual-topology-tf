##
#  topology.dot file parsing
#

data "local_file" "topology" {
  filename = "${path.module}/${var.topology_file}"
}

locals {
  # topology nodes
  topology_objects = jsondecode(data.local_file.topology.content).objects
  hosts = { for o in local.topology_objects: (o.name) => o._gvid }
  hosts_ = { for o in local.topology_objects: (o._gvid) => o.name }
  host_params = { for o in local.topology_objects:
            (o.name) => {
              id = o._gvid
              cpu = lookup(o, "cpu", null) != null ? tonumber(o.cpu) : null
              memory = lookup(o, "memory", null) != null ? tonumber(o.memory) : null
            }
  }

  # topology links
  topology_edges = jsondecode(data.local_file.topology.content).edges
  links = merge(
    # forward links
    { for o in local.topology_edges: (local.hosts_[o.head]) => {
      link_id = o._gvid
      src_id = o.head
      dst_id = o.tail
      src_port = o.headport
      dst_port = o.tailport
      dst_host = local.hosts_[o.tail]
    }...},
    # reverse links
    { for o in local.topology_edges: (local.hosts_[o.tail]) => {
      link_id = o._gvid
      src_id = o.tail
      dst_id = o.head
      src_port = o.tailport
      dst_port = o.headport
      dst_host = local.hosts_[o.head]
    }...}
  )
}
