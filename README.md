# Azure Tailscale Exit Node (India)

Low-cost, on-demand Tailscale exit node in Azure Central India. Spot B1s VM auto-starts via HTTP function, auto-shuts after 8h idle, and exposes a simple activity endpoint for health/idle checks.

```
                +-------------------+
                | GitHub Actions    |
                | bicep/terraform   |
                +---------+---------+
                          |
                    OIDC Deploy
                          |
+---------+    +----------v----------+      +--------------------+
| Client  |    | Azure Functions     |      |  Log Analytics     |
| tailscale|<--| start-vm (HTTP)     |----->|  budget/diagnostic |
| device  |    | shutdown-vm (timer) |      +--------------------+
+----+----+    +----------+----------+
     |                    |
     | tailscale up       | start/deallocate VM
     v                    v
+----+--------------------------------------+
|  Spot VM (Ubuntu 22.04, B1s, Central India)|
|  - Tailscale exit node & NAT               |
|  - Activity endpoint :8080/activity        |
+--------------------------------------------+
```

## Prerequisites
- Azure subscription and `Owner` or `Contributor` + `User Access Administrator` on target subscription
- GitHub repo with OIDC federation to Azure (client ID, tenant ID, subscription ID stored as secrets)
- Tailscale account with reusable auth key (server, reusable, preapproved)
- Azure CLI ≥ 2.56, Bicep CLI, Terraform ≥ 1.6 (optional)
- Python 3.11 for local Function packaging if deploying manually

## Azure CLI setup
```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
```

## Tailscale setup
1. Create auth key: https://login.tailscale.com/admin/settings/keys (Server; mark **Ephemeral** to auto-clean nodes when they go away, no extra flags needed; otherwise reusable & preapproved)
2. Note the key (used as `tailscaleAuthKey` parameter and `TAILSCALE_AUTH_KEY` secret).

## Deploy with Make (Bicep + Functions)
These commands wrap the Azure CLI steps:

- `make deploy` — creates the RG (if needed) and deploys all infrastructure (VM, network, Function App, identities). Requires `TAILSCALE_AUTH_KEY` and your SSH public key (defaults to `~/.ssh/id_ed25519.pub`).
- `make functions` — zips and publishes the function code to the Function App created above.
- `make all` — runs both: infra + function code.
- `make outputs` — prints deployment outputs (function host, exit-node name, public IP, start-vm URL).
- `make start` — calls the start-vm function URL to boot the VM.
- `make client-up` — runs `tailscale up` locally using the exit-node name from deployment outputs.

### One-time local setup
Create a `.env` file in the repo root so Make picks up secrets automatically (no need to `source` each time):
```
TAILSCALE_AUTH_KEY=tskey-...   # server key (ephemeral recommended)
SSH_KEY=~/.ssh/id_ed25519.pub   # optional override of the SSH public key path
```
The Makefile auto-loads `.env` and will fail fast if `TAILSCALE_AUTH_KEY` is missing.

Example:
```bash
# with .env present, no extra exports needed
make all
make outputs
make start       # boot the VM
make client-up   # point your client at the exit node
```

## Deploy with Terraform (alternative)
```bash
cd infra/terraform
terraform init
terraform apply \
  -var subscription_id=$SUBSCRIPTION_ID \
  -var tailscale_auth_key=$TAILSCALE_AUTH_KEY
```

## CI/CD (GitHub Actions)
Workflow `.github/workflows/azure-deploy.yml`:
- Validate Bicep
- Create resource group (idempotent) in `LOCATION`
- Deploy `infra/bicep/rg.bicep` via `az deployment group create`
- Package & zip Azure Functions and push via `az functionapp deployment source config-zip`
Required secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TAILSCALE_AUTH_KEY`.

## Starting the VPN
1. Start VM on-demand (boot ≈ 30s):
```bash
curl https://<function-host>/api/start-vm
```
2. From your client, bring Tailscale up using the exit node hostname (VM name + `-exit`) as shown in deployment outputs (or use its 100.x tailnet IP). Exit routing expects both IPv4 and IPv6 routes:

- **macOS / Linux**
```bash
tailscale up --exit-node=<hostname>
curl ifconfig.me
```
- **Windows (PowerShell)**
```powershell
tailscale up --exit-node=<hostname>
Invoke-WebRequest -UseBasicParsing ifconfig.me
```
If IP is in India, routing works.

If the node isn’t listed by name, connect with its tailnet IP:
```bash
tailscale up --exit-node=100.x.y.z
```

## Auto-shutdown logic
- VM runs activity tracker watching iptables counters and writing `/var/lib/activity/last_activity`
- HTTP endpoint `http://<vm-ip>:8080/activity` returns `{ "last_activity_timestamp": <epoch> }`
- Timer-triggered function hits the endpoint hourly; if idle ≥ 8 hours, VM is deallocated (Spot eviction policy also deallocates)

## Monitoring
- Log Analytics workspace (`ts-logs`) receives diagnostics from VM and Function App
- Sample KQL: see `docs/monitoring.md`
- Budget alert: $10/month at subscription scope

## Troubleshooting
- VM not visible in Tailscale: check `tailscale status` on VM via SSH or restart `sudo systemctl restart tailscaled`
- Start function fails: verify managed identity has `Virtual Machine Contributor` and `Network Contributor` on the resource group
- Shutdown not happening: confirm activity endpoint reachable; check Function traces in Application Insights (Log Analytics)

## Cost estimate (approx)
- Spot B1s VM: ~$6–8/mo if always on; actual lower because auto-shutdown
- Storage + PIP + Function Consumption + Log Analytics: typically <$2/mo at low volume
- Budget enforces $10/mo warning

## Repo structure
- `infra/bicep`: primary IaC (subscription-scope deployment, diagnostics, budget)
- `infra/terraform`: alternative IaC
- `functions/start_vm_function` & `shutdown_vm_function`: Azure Functions (Python)
- `scripts`: cloud-init and helper scripts
- `.github/workflows`: CI/CD pipeline
- `docs`: monitoring queries
