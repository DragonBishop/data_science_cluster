"""Rendered network configuration preserves the publication boundaries."""

import subprocess
from functools import cache
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]


@cache
def build(directory: str) -> tuple[dict, ...]:
    """Render a kustomize directory once and return its documents."""
    result = subprocess.run(
        ["kubectl", "kustomize", str(REPO_ROOT / directory)],
        cwd=REPO_ROOT,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(f"kubectl kustomize {directory} failed:\n{result.stderr}")
    return tuple(document for document in yaml.safe_load_all(result.stdout) if document)


def find(directory: str, kind: str, name: str) -> dict:
    """Return the one object of a kind and name that a directory renders."""
    matches = [
        document
        for document in build(directory)
        if document["kind"] == kind and document["metadata"]["name"] == name
    ]
    assert len(matches) == 1, f"expected one {kind}/{name} in {directory}"
    return matches[0]


def permitted_ports(rule: dict) -> set[tuple[str, str]]:
    """Return a policy rule's ports as (port, protocol) pairs."""
    return {
        (port["port"], port["protocol"])
        for port_group in rule["toPorts"]
        for port in port_group["ports"]
    }


def test_baseline_admits_only_the_host_to_every_pod():
    """The baseline admits only the host to pods; each receiver's policy decides what the Gateway reaches."""
    policy = find(
        "infrastructure/cilium", "CiliumClusterwideNetworkPolicy", "cluster-default"
    )
    pod_rules = [rule for rule in policy["specs"] if rule["endpointSelector"] == {}]
    assert len(pod_rules) == 1
    assert pod_rules[0]["ingress"] == [{"fromEntities": ["host"]}]


def test_gateway_listeners_admit_the_database_namespace():
    """Every Gateway listener accepts routes from the databases namespace."""
    gateway = find("infrastructure/gateway/server", "Gateway", "internal-gateway")
    namespace = find("infrastructure/namespaces", "Namespace", "databases")
    namespace_labels = namespace["metadata"]["labels"]
    for listener in gateway["spec"]["listeners"]:
        allowed_namespaces = listener["allowedRoutes"]["namespaces"]
        assert allowed_namespaces["from"] == "Selector"
        required_labels = allowed_namespaces["selector"]["matchLabels"]
        assert required_labels
        assert required_labels.items() <= namespace_labels.items()


def test_database_policy_admits_the_gateway_on_the_published_port():
    """PostgreSQL's policy admits the Gateway on exactly the port its TCPRoute publishes."""
    route = find("apps/databases/cluster", "TCPRoute", "postgres-external")
    policy = find("apps/databases/security", "CiliumNetworkPolicy", "postgres-cluster")
    published_port = str(route["spec"]["rules"][0]["backendRefs"][0]["port"])
    gateway_rules = [
        rule
        for rule in policy["spec"]["ingress"]
        if rule.get("fromEntities") == ["ingress"]
    ]
    assert len(gateway_rules) == 1
    assert permitted_ports(gateway_rules[0]) == {(published_port, "TCP")}
