import asyncio
import importlib
import json
import sys
import types
from pathlib import Path

import azure.functions as func
import pytest

# Ensure the function modules are importable regardless of where pytest is invoked from.
sys.path.append(str(Path(__file__).resolve().parents[1]))


def _reload_start_module(monkeypatch, env: dict):
    for key in ["SUBSCRIPTION_ID", "RESOURCE_GROUP_NAME", "VM_NAME", "PUBLIC_IP_NAME", "LOCATION"]:
        if key in env:
            monkeypatch.setenv(key, env[key])
        else:
            monkeypatch.delenv(key, raising=False)

    # Stub Azure clients to avoid real network calls at import time.
    class FakeComputeVMs:
        def begin_start(self, *_args, **_kwargs):
            return types.SimpleNamespace(wait=lambda: None)

        def instance_view(self, *_args, **_kwargs):
            status = types.SimpleNamespace(display_status="VM running")
            return types.SimpleNamespace(statuses=[status])

    class FakeComputeClient:
        def __init__(self, *_args, **_kwargs):
            self.virtual_machines = FakeComputeVMs()

    class FakePublicIP:
        def get(self, *_args, **_kwargs):
            return types.SimpleNamespace(ip_address="1.2.3.4")

    class FakeNetworkClient:
        def __init__(self, *_args, **_kwargs):
            self.public_ip_addresses = FakePublicIP()

    monkeypatch.setattr("azure.identity.DefaultAzureCredential", lambda **_kwargs: object())
    monkeypatch.setattr("azure.mgmt.compute.ComputeManagementClient", FakeComputeClient)
    monkeypatch.setattr("azure.mgmt.network.NetworkManagementClient", FakeNetworkClient)

    import start_vm_function

    return importlib.reload(start_vm_function)


def _reload_shutdown_module(monkeypatch, env: dict, idle_seconds: int = 0):
    for key in ["SUBSCRIPTION_ID", "RESOURCE_GROUP_NAME", "VM_NAME", "PUBLIC_IP_NAME", "MAX_IDLE_SECONDS"]:
        if key in env:
            monkeypatch.setenv(key, env[key])
        else:
            monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("MAX_IDLE_SECONDS", str(idle_seconds))

    class FakeComputeClient:
        def __init__(self, *_args, **_kwargs):
            pass

        def begin_deallocate(self, *_args, **_kwargs):
            return types.SimpleNamespace(wait=lambda: None)

        def get(self, *_args, **_kwargs):
            running = types.SimpleNamespace(code="PowerState/running")
            instance_view = types.SimpleNamespace(statuses=[running])
            return types.SimpleNamespace(instance_view=instance_view)

        @property
        def virtual_machines(self):
            return self

    class FakeNetworkClient:
        def __init__(self, *_args, **_kwargs):
            pass

        def get(self, *_args, **_kwargs):
            return types.SimpleNamespace(ip_address="10.0.0.1")

        @property
        def public_ip_addresses(self):
            return self

    monkeypatch.setattr("azure.identity.DefaultAzureCredential", lambda **_kwargs: object())
    monkeypatch.setattr("azure.mgmt.compute.ComputeManagementClient", FakeComputeClient)
    monkeypatch.setattr("azure.mgmt.network.NetworkManagementClient", FakeNetworkClient)

    import shutdown_vm_function

    return importlib.reload(shutdown_vm_function)


def test_start_vm_missing_env_returns_500(monkeypatch):
    mod = _reload_start_module(monkeypatch, env={})
    req = func.HttpRequest(method="GET", url="/api/start-vm", body=b"")
    resp = asyncio.run(mod.main(req))
    assert resp.status_code == 500
    assert b"Missing required" in resp.get_body()


def test_start_vm_happy_path(monkeypatch):
    mod = _reload_start_module(
        monkeypatch,
        env={
            "SUBSCRIPTION_ID": "sub",
            "RESOURCE_GROUP_NAME": "rg",
            "VM_NAME": "vm",
            "PUBLIC_IP_NAME": "pip",
            "LOCATION": "centralindia",
        },
    )
    req = func.HttpRequest(method="GET", url="/api/start-vm", body=b"")
    resp = asyncio.run(mod.main(req))
    assert resp.status_code == 200
    body = json.loads(resp.get_body())
    assert body["publicIp"] == "1.2.3.4"
    assert body["vmName"] == "vm"
    assert body["location"] == "centralindia"


def test_shutdown_skips_when_idle(monkeypatch):
    # Idle threshold set low so the VM should deallocate.
    mod = _reload_shutdown_module(
        monkeypatch,
        env={
            "SUBSCRIPTION_ID": "sub",
            "RESOURCE_GROUP_NAME": "rg",
            "VM_NAME": "vm",
            "PUBLIC_IP_NAME": "pip",
        },
        idle_seconds=0,
    )

    # Mock activity endpoint to return very old timestamp.
    monkeypatch.setattr(
        mod,
        "requests",
        types.SimpleNamespace(
            get=lambda *_args, **_kwargs: types.SimpleNamespace(
                raise_for_status=lambda: None, json=lambda: {"last_activity_timestamp": 0}
            )
        ),
    )

    # Track if deallocate was called.
    called = {"ran": False}

    def fake_deallocate(*_a, **_k):
        called["ran"] = True
        return True

    monkeypatch.setattr(mod, "_deallocate_vm", fake_deallocate)

    # Run timer function.
    asyncio.run(mod.main(types.SimpleNamespace(past_due=False)))
    assert called["ran"] is True
