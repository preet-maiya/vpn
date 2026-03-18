# Load variables from .env if present (KEY=VALUE lines)
-include .env
export $(shell sed -n 's/^[[:space:]]*\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' .env 2>/dev/null)

# Configuration
RG ?= ts-exit-rg
LOCATION ?= centralindia
DEPLOY ?= ts-exit-deploy
TEMPLATE ?= infra/bicep/rg.bicep
SSH_KEY ?= ~/.ssh/id_ed25519.pub
# Use existing Azure CLI login; disable log file to avoid perms issues
AZCLI ?= AZURE_DISABLE_LOG_FILE=1 az

# Environment required:
# - AZURE_SUBSCRIPTION_ID (or set via `az account set`)
# - TAILSCALE_AUTH_KEY (server, reusable) for deployment

.PHONY: all rg deploy outputs functions start client-up clean-zip
.PHONY: nuke
.PHONY: client-down client-up-safe
.PHONY: check-key

all: deploy functions

# Create resource group (idempotent)
rg:
	$(AZCLI) group create -n $(RG) -l $(LOCATION)

# Deploy infra (VM, network, function app, identities). Uses TAILSCALE_AUTH_KEY.
deploy: check-key rg
	$(AZCLI) deployment group create \
		-g $(RG) \
		--name $(DEPLOY) \
		--mode Complete \
		--template-file $(TEMPLATE) \
		--parameters location=$(LOCATION) tailscaleAuthKey=$$TAILSCALE_AUTH_KEY sshPublicKey="$$(cat $(SSH_KEY))"

# Show deployment outputs (function host, exit node name, public IP, etc.)
outputs:
	$(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) --query "properties.outputs"

# Package and zip-deploy function code to the created Function App.
functions: clean-zip
	cd functions && zip -r ../functions.zip *
	APP_NAME=$$($(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) \
		--query "properties.outputs.functionAppId.value" -o tsv | awk -F/ '{print $$NF}'); \
	if [ -z "$$APP_NAME" ]; then \
		APP_NAME=$$($(AZCLI) functionapp list -g $(RG) --query "[?starts_with(name, 'ts-exit-func')].name | [0]" -o tsv); \
	fi; \
	test -n "$$APP_NAME" || (echo "Function App name not found; ensure deploy succeeded or set APP_NAME manually" && exit 1); \
	$(AZCLI) functionapp config appsettings set -g $(RG) -n $$APP_NAME --settings SCM_DO_BUILD_DURING_DEPLOYMENT=true > /dev/null; \
	$(AZCLI) functionapp deployment source config-zip -g $(RG) -n $$APP_NAME --src functions.zip

# Start the VM via the function output URL.
start:
	URL=$$($(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) \
		--query "properties.outputs.startFunctionUrl.value" -o tsv); \
	curl $$URL

# Bring the local client up using the exit node name from outputs.
client-up:
	EXIT_NODE=$$($(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) \
		--query "properties.outputs.tailscaleHostname.value" -o tsv); \
	tailscale up --exit-node=$$EXIT_NODE

client-down:
	tailscale down

client-up-safe:
	EXIT_NODE=$$($(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) \
		--query "properties.outputs.tailscaleHostname.value" -o tsv); \
	START_URL=$$($(AZCLI) deployment group show -g $(RG) -n $(DEPLOY) \
		--query "properties.outputs.startFunctionUrl.value" -o tsv); \
	echo "Starting VM via $$START_URL"; \
	curl -fsS $$START_URL >/dev/null; \
	echo "Waiting for exit node $$EXIT_NODE to appear in tailscale status..."; \
	for i in $$(seq 1 18); do \
		if tailscale status --peers | grep -qw "$$EXIT_NODE"; then \
			echo "Exit node is online"; \
			break; \
		fi; \
		sleep 10; \
	done; \
	if ! tailscale status --peers | grep -qw "$$EXIT_NODE"; then \
		echo "Exit node not found after waiting; aborting"; \
		exit 1; \
	fi; \
	tailscale up --exit-node=$$EXIT_NODE

# Danger: deletes the entire resource group and everything in it.
nuke:
nuke:
	$(AZCLI) group delete -n $(RG) --yes --no-wait

check-key:
	@test -n "$(TAILSCALE_AUTH_KEY)" || (echo "ERROR: TAILSCALE_AUTH_KEY is empty. Set it in .env or export it before running make." && exit 1)

clean-zip:
	@rm -f functions.zip

.PHONY: test
test:
	cd functions && python -m pip install -r requirements.txt && python -m pip install pytest
	cd functions && pytest
