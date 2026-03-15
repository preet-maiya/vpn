#!/usr/bin/env bash
# Installs and configures Tailscale exit node. Requires a Tailscale auth key passed as $1.
set -euo pipefail
AUTH_KEY=${1:-"__TAILSCALE_AUTH_KEY__"}
HOSTNAME=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text")

curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
apt-get update
apt-get install -y tailscale

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tailscale.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale.conf

PRIMARY_IF=$(ip route show default | awk '/default/ {print $5; exit}')
iptables -t nat -A POSTROUTING -o "$PRIMARY_IF" -j MASQUERADE
iptables -A FORWARD -i tailscale0 -o "$PRIMARY_IF" -j ACCEPT
iptables -A FORWARD -i "$PRIMARY_IF" -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save || true

systemctl enable --now tailscaled
sleep 5
tailscale up \
  --auth-key "$AUTH_KEY" \
  --hostname "$HOSTNAME-exit" \
  --advertise-exit-node \
  --advertise-routes=0.0.0.0/0,::/0 \
  --ssh

/usr/local/bin/update-activity.sh "tailscale-up"
