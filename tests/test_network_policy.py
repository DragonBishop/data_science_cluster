"""Rendered network configuration preserves the publication boundaries."""

import yaml

from tests.test_cluster_config_drift import REPO_ROOT, run_command


def built_resource(directory: str, kind: str, name: str) -> dict:
    documents = yaml.safe_load_all(
        run_command(["kubectl", "kustomize", str(REPO_ROOT / directory)])
    )
    matches = [
        document
        for document in documents
        if document
        and document["kind"] == kind
        and document["metadata"]["name"] == name
    ]
    assert len(matches) == 1, f"expected one {kind}/{name} in {directory}"
    return matches[0]


def test_gateway_namespace_selectors_admit_the_database_namespace():
    gateway = built_resource("infrastructure/gateway", "Gateway", "internal-gateway")
    namespace = built_resource("infrastructure/namespaces", "Namespace", "databases")
    for listener in gateway["spec"]["listeners"]:
        namespace_rule = listener["allowedRoutes"]["namespaces"]
        assert namespace_rule["from"] == "Selector"
        required_labels = namespace_rule["selector"]["matchLabels"]
        assert required_labels
        for label_name, expected_setting in required_labels.items():
            assert namespace["metadata"]["labels"].get(label_name) == expected_setting


def test_database_gateway_permission_matches_the_published_port():
    route = built_resource("apps/databases", "TCPRoute", "postgres-external")
    policy = built_resource("apps/databases", "CiliumNetworkPolicy", "postgres-cluster")
    backend_port = route["spec"]["rules"][0]["backendRefs"][0]["port"]
    gateway_rules = [
        rule
        for rule in policy["spec"]["ingress"]
        if "ingress" in rule.get("fromEntities", [])
    ]
    assert len(gateway_rules) == 1
    assert gateway_rules[0]["fromEntities"] == ["ingress"]
    permitted_ports = {
        (port["port"], port["protocol"])
        for port_group in gateway_rules[0]["toPorts"]
        for port in port_group["ports"]
    }
    assert permitted_ports == {(str(backend_port), "TCP")}
