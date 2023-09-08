##
#  topology.dot file parsing
#

provider "external" { }

data "external" "hosts" {
  program = ["./query-topology.sh"]
}
data "external" "cpu" {
  program = ["./query-topology.sh"]
  query = {
    topology_file = var.topology_file
    q = "cpu"
  }
}
data "external" "memory" {
  program = ["./query-topology.sh"]
  query = {
    topology_file = var.topology_file
    q = "memory"
  }
}

locals {
  # host => name, string - graphviz node name
  # id => _gvid, number - graphiz node id
  hosts = { for host, i in data.external.hosts.result: host => tonumber(i) }
  memory = { for k, v in data.external.memory.result: k => v != "null" ? v : null }
  cpu = { for k, v in data.external.cpu.result: k => v != "null" ? v : null }
  # NOTE: os/version unsupported yet
  host_params = { for host, i in local.hosts:
    host => {
      memory = local.memory[host]
      cpu = local.cpu[host]
    }
  }
}
