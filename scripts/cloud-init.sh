#cloud-config
package_update: true
package_upgrade: true
packages:
  - python3
  - python3-venv
  - python3-pip
  - iptables
  - iptables-persistent
  - curl
  - jq
  - git
  - ca-certificates
  - apt-transport-https
  - conntrack

write_files:
  - path: /usr/local/bin/tailscale-install.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      AUTH_KEY="__TAILSCALE_AUTH_KEY__"
      HOSTNAME=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text")
      
      curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
      curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
      apt-get update
      apt-get install -y tailscale

      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv6.conf.all.forwarding=1
      echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tailscale.conf
      echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale.conf

      # MASQUERADE traffic leaving via primary interface
      PRIMARY_IF=$(ip route show default | awk '/default/ {print $5; exit}')
      iptables -t nat -A POSTROUTING -o "$PRIMARY_IF" -j MASQUERADE
      iptables -A FORWARD -i tailscale0 -o "$PRIMARY_IF" -j ACCEPT
      iptables -A FORWARD -i "$PRIMARY_IF" -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      # Persist iptables rules if the helper is available; otherwise continue
      netfilter-persistent save || true

      systemctl enable --now tailscaled
      sleep 5

      echo "[DEBUG] Tailscale auth key: $AUTH_KEY"

      # Retry tailscale up a few times in case network/metadata isn't ready on first boot
      # Use an ephemeral auth key so the node auto-cleans when the VM goes away.
      for i in $(seq 1 5); do
        if tailscale up \
          --auth-key "$AUTH_KEY" \
          --hostname "$HOSTNAME-exit" \
          --advertise-exit-node \
          --advertise-routes=0.0.0.0/0,::/0 \
          --ssh; then
          break
        fi
        echo "tailscale up attempt $i failed; retrying..."
        sleep 5
      done

      # Record initial activity timestamp
      /usr/local/bin/update-activity.sh "tailscale-up"

  - path: /usr/local/bin/update-activity.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      TS_FILE=/var/lib/activity/last_activity
      mkdir -p $(dirname "$TS_FILE")
      date +%s > "$TS_FILE"

  - path: /usr/local/bin/activity-tracker.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      TS_FILE=/var/lib/activity/last_activity
      mkdir -p $(dirname "$TS_FILE")
      # Initialize if missing
      if [ ! -f "$TS_FILE" ]; then
        date +%s > "$TS_FILE"
      fi

      # Baseline packet counters
      prev=$(iptables -nvx -L FORWARD 2>/dev/null | awk 'NR==3 {print $2 "+" $3}')
      while true; do
        sleep 60
        curr=$(iptables -nvx -L FORWARD 2>/dev/null | awk 'NR==3 {print $2 "+" $3}')
        if [ "$curr" != "$prev" ]; then
          date +%s > "$TS_FILE"
          prev=$curr
        fi
      done

  - path: /usr/local/bin/activity-endpoint.py
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env python3
      import json
      import time
      from http.server import BaseHTTPRequestHandler, HTTPServer
      TS_FILE = "/var/lib/activity/last_activity"

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path != "/activity":
                  self.send_response(404)
                  self.end_headers()
                  return
              try:
                  with open(TS_FILE, "r") as f:
                      ts = int(f.read().strip())
              except Exception:
                  ts = int(time.time())
              payload = {"last_activity_timestamp": ts}
              body = json.dumps(payload).encode()
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, format, *args):
              return

      if __name__ == "__main__":
          server = HTTPServer(("0.0.0.0", 8080), Handler)
          server.serve_forever()

  - path: /etc/systemd/system/activity-tracker.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Tailscale exit node activity tracker
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/activity-tracker.sh
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/activity-endpoint.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Activity endpoint on 8080
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/activity-endpoint.py
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

runcmd:
  - bash /usr/local/bin/tailscale-install.sh
  - systemctl daemon-reload
  - systemctl enable --now activity-tracker.service
  - systemctl enable --now activity-endpoint.service
