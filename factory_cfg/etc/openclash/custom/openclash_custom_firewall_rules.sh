#!/bin/sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# This script is called by /etc/init.d/openclash
# Add your custom firewall rules here, they will be added after the end of the OpenClash iptables rules

LOG_TIP "Start Add Custom Firewall Rules..."

# fix: UDP DNS must skip TPROXY, otherwise the DNS-hijack redirect rewrites
# the destination after tproxy-marking and clash tunnels the query to a
# private address (queries blackhole)
(
  i=0
  while [ "$i" -lt 30 ]; do
    nft list chain inet fw4 openclash_mangle >/dev/null 2>&1 && break
    sleep 1
    i=$((i+1))
  done
  if nft list chain inet fw4 openclash_mangle >/dev/null 2>&1; then
    nft list chain inet fw4 openclash_mangle | grep -q "udp dport 53" || \
      nft insert rule inet fw4 openclash_mangle udp dport 53 counter return
  fi
) &

exit 0
