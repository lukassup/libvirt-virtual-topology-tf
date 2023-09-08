#!/bin/bash -ex
eval "$(jq -r '@sh "TOPOLOGY_FILE=\(.topology_file // "") Q=\(.q // "")"')"
: ${Q:=_gvid}
: ${TOPOLOGY_FILE:=topology.dot}
dot -Tdot_json "$TOPOLOGY_FILE" | jq -r --arg Q "$Q" '[.objects[] | {key: .name, value: .[$Q]|tostring}] | from_entries'
