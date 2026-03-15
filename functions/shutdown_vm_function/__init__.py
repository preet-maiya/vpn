import json
import logging
import os
import time
import requests
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient

SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID")
RESOURCE_GROUP = os.environ.get("RESOURCE_GROUP_NAME")
VM_NAME = os.environ.get("VM_NAME")
PUBLIC_IP_NAME = os.environ.get("PUBLIC_IP_NAME")
MAX_IDLE_SECONDS = int(os.environ.get("MAX_IDLE_SECONDS", str(1 * 3600)))

credential = DefaultAzureCredential(exclude_shared_token_cache_credential=True)
compute_client = ComputeManagementClient(credential, SUBSCRIPTION_ID)
network_client = NetworkManagementClient(credential, SUBSCRIPTION_ID)


def _get_public_ip():
    pip = network_client.public_ip_addresses.get(RESOURCE_GROUP, PUBLIC_IP_NAME)
    return pip.ip_address


def _is_vm_running():
    instance = compute_client.virtual_machines.get(RESOURCE_GROUP, VM_NAME, expand="instanceView")
    for status in instance.instance_view.statuses:
        if status.code == "PowerState/running":
            return True
    return False


def _deallocate_vm():
    poller = compute_client.virtual_machines.begin_deallocate(RESOURCE_GROUP, VM_NAME)
    poller.wait()
    return True


def _get_last_activity(ip_addr: str) -> int:
    url = f"http://{ip_addr}:8080/activity"
    resp = requests.get(url, timeout=5)
    resp.raise_for_status()
    data = resp.json()
    return int(data.get("last_activity_timestamp", 0))


async def main(mytimer: func.TimerRequest) -> None:
    if not all([SUBSCRIPTION_ID, RESOURCE_GROUP, VM_NAME, PUBLIC_IP_NAME]):
        logging.error("Missing required app settings; skipping shutdown check")
        return

    if not _is_vm_running():
        logging.info("VM not running; nothing to do")
        return

    ip_addr = _get_public_ip()
    try:
        last_ts = _get_last_activity(ip_addr)
    except Exception as ex:
        logging.warning("Failed to query activity endpoint: %s", ex)
        return

    idle_for = int(time.time()) - last_ts
    if idle_for >= MAX_IDLE_SECONDS:
        logging.info("VM idle for %s seconds; deallocating", idle_for)
        _deallocate_vm()
    else:
        logging.info("VM idle %s seconds; keeping running", idle_for)
