import logging
import os
import json
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient

SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID")
RESOURCE_GROUP = os.environ.get("RESOURCE_GROUP_NAME")
VM_NAME = os.environ.get("VM_NAME")
PUBLIC_IP_NAME = os.environ.get("PUBLIC_IP_NAME")
# Region is supplied via app settings; don't hardcode a fallback so deployments can choose any region.
LOCATION = os.environ.get("LOCATION", "")

credential = DefaultAzureCredential(exclude_shared_token_cache_credential=True)
compute_client = ComputeManagementClient(credential, SUBSCRIPTION_ID)
network_client = NetworkManagementClient(credential, SUBSCRIPTION_ID)

async def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Received start-vm request")
    if not all([SUBSCRIPTION_ID, RESOURCE_GROUP, VM_NAME, PUBLIC_IP_NAME]):
        return func.HttpResponse("Missing required app settings", status_code=500)

    # Start the VM (idempotent)
    poller = compute_client.virtual_machines.begin_start(RESOURCE_GROUP, VM_NAME)
    poller.wait()

    # Fetch instance view for status
    instance_view = compute_client.virtual_machines.instance_view(RESOURCE_GROUP, VM_NAME)
    statuses = [s.display_status for s in instance_view.statuses]

    # Fetch public IP
    pip = network_client.public_ip_addresses.get(RESOURCE_GROUP, PUBLIC_IP_NAME)
    ip_addr = pip.ip_address

    body = {
        "vmName": VM_NAME,
        "status": statuses,
        "publicIp": ip_addr,
        "location": LOCATION,
    }
    return func.HttpResponse(body=json.dumps(body), status_code=200, mimetype="application/json")
