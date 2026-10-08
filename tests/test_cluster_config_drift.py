"""Tests that Flux and Ansible resolve every cluster-config variable they use."""

import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
CLUSTER_CONFIG_DIR = REPO_ROOT / "infrastructure/cluster-config"
FLUX_KUSTOMIZATIONS_DIR = REPO_ROOT / "clusters/local"
ANSIBLE_ROUTES_PATH = REPO_ROOT / "ansible/inventory/group_vars/all/cluster_config.yml"
ANSIBLE_JSON_OUTPUT = {
    "ANSIBLE_STDOUT_CALLBACK": "ansible.posix.json",
    "ANSIBLE_LOAD_CALLBACK_PLUGINS": "1",
}


def run_command(arguments: list[str], environment: dict[str, str] | None = None) -> str:
    """Run a command from the repo root and return its stdout, failing the test on a non-zero exit."""
    result = subprocess.run(
        arguments,
        cwd=REPO_ROOT,
        env={**os.environ, **(environment or {})},
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(f"{' '.join(arguments)} failed:\n{result.stderr}\n{result.stdout}")
    return result.stdout


def substitutes_cluster_config(document: dict | None) -> bool:
    """Return whether a document is a Flux Kustomization that substitutes from cluster-config."""
    if not document or document.get("kind") != "Kustomization":
        return False
    sources = document.get("spec", {}).get("postBuild", {}).get("substituteFrom", [])
    return any(
        source.get("kind") == "ConfigMap" and source.get("name") == "cluster-config"
        for source in sources
    )


def find_substituted_kustomizations() -> list[dict]:
    """Return the Flux Kustomizations that substitute from cluster-config."""
    return [
        document
        for kustomization_file in sorted(FLUX_KUSTOMIZATIONS_DIR.glob("*.yaml"))
        for document in yaml.safe_load_all(kustomization_file.read_text())
        if substitutes_cluster_config(document)
    ]


def build_flux_kustomization(
    kustomization: dict, cluster_config_data: dict[str, str], work_dir: Path
) -> list[dict]:
    """Build a Flux Kustomization offline and return its manifests.

    cluster-config is inlined as substitute values because --dry-run skips ConfigMap lookups.
    """
    post_build = kustomization["spec"]["postBuild"]
    offline_kustomization = {
        **kustomization,
        "spec": {
            **kustomization["spec"],
            "postBuild": {
                **post_build,
                "substitute": {
                    **cluster_config_data,
                    **post_build.get("substitute", {}),
                },
                "substituteFrom": [
                    source
                    for source in post_build["substituteFrom"]
                    if source.get("name") != "cluster-config"
                ],
            },
        },
    }
    kustomization_name = kustomization["metadata"]["name"]
    kustomization_file = work_dir / f"{kustomization_name}.yaml"
    kustomization_file.write_text(yaml.safe_dump(offline_kustomization))
    rendered_manifests = run_command(
        [
            "flux",
            "build",
            "kustomization",
            kustomization_name,
            "--path",
            kustomization["spec"]["path"],
            "--kustomization-file",
            str(kustomization_file),
            "--dry-run",
            "--strict-substitute",
        ]
    )
    return [document for document in yaml.safe_load_all(rendered_manifests) if document]


def parse_ansible_task_result(ansible_output: str) -> dict:
    """Return the first task's localhost result from Ansible JSON callback output."""
    return json.loads(ansible_output)["plays"][0]["tasks"][0]["hosts"]["127.0.0.1"]


def evaluate_ansible_variables(variable_names: list[str]) -> dict:
    """Return the named variables as Ansible evaluates them from the repo root."""
    output = run_command(
        [
            "ansible",
            "localhost",
            "-m",
            "ansible.builtin.debug",
            "-a",
            "msg={{ dict(requested_variables | zip(query('ansible.builtin.vars', *requested_variables))) }}",
            "-e",
            json.dumps({"requested_variables": variable_names}),
        ],
        environment=ANSIBLE_JSON_OUTPUT,
    )
    return parse_ansible_task_result(output)["msg"]


def run_role_tasks(role: str, tasks_from: str, work_dir: Path) -> dict:
    """Run one of a role's task files in a throwaway playbook and return its first task's result.

    The playbook sits outside the repo, so repo_root is passed as an extra var.
    """
    playbook_file = work_dir / "playbook.yml"
    playbook_file.write_text(
        yaml.safe_dump(
            [
                {
                    "hosts": "localhost",
                    "gather_facts": False,
                    "tasks": [
                        {
                            "ansible.builtin.import_role": {
                                "name": role,
                                "tasks_from": tasks_from,
                            }
                        }
                    ],
                }
            ]
        )
    )
    output = run_command(
        [
            "ansible-playbook",
            str(playbook_file),
            "-e",
            json.dumps({"repo_root": str(REPO_ROOT)}),
        ],
        environment=ANSIBLE_JSON_OUTPUT,
    )
    return parse_ansible_task_result(output)


@pytest.fixture(scope="module")
def cluster_config_data() -> dict[str, str]:
    """Return the cluster-config ConfigMap data as kustomize builds it."""
    built_configmap = yaml.safe_load(
        run_command(["kubectl", "kustomize", str(CLUSTER_CONFIG_DIR)])
    )
    return built_configmap["data"]


def test_substituted_kustomizations_found():
    """Check that discovery finds Kustomizations, so the parametrized test can't pass empty."""
    assert find_substituted_kustomizations(), (
        f"no Kustomization in {FLUX_KUSTOMIZATIONS_DIR} substitutes from cluster-config"
    )


@pytest.mark.parametrize(
    "kustomization",
    find_substituted_kustomizations(),
    ids=lambda kustomization: kustomization["metadata"]["name"],
)
def test_flux_kustomization_renders_every_variable(
    kustomization: dict, cluster_config_data: dict[str, str], tmp_path: Path
):
    """Check that Flux builds the Kustomization with no ${VAR} left unset."""
    build_flux_kustomization(kustomization, cluster_config_data, tmp_path)


def test_ansible_cluster_config_matches_flux_configmap(
    cluster_config_data: dict[str, str],
):
    """Check that Ansible's merged cluster_config equals the ConfigMap Flux applies."""
    ansible_cluster_config = evaluate_ansible_variables(["cluster_config"])[
        "cluster_config"
    ]
    assert ansible_cluster_config == cluster_config_data


def test_ansible_routed_variables_resolve():
    """Check that every routed Ansible variable resolves to a non-empty value."""
    routed_variable_names = list(yaml.safe_load(ANSIBLE_ROUTES_PATH.read_text()))
    routed_values = evaluate_ansible_variables(routed_variable_names)
    empty_variables = [
        name for name, value in routed_values.items() if value in ("", None)
    ]
    assert empty_variables == []


def test_ansible_cilium_values_match_flux(
    cluster_config_data: dict[str, str], tmp_path: Path
):
    """Check that Ansible renders the same Cilium values as Flux's cilium-values ConfigMap."""
    ansible_values = yaml.safe_load(
        run_role_tasks("data_science.cluster.cilium", "render_values", tmp_path)[
            "stdout"
        ]
    )

    cilium_kustomization = next(
        (
            kustomization
            for kustomization in find_substituted_kustomizations()
            if kustomization["metadata"]["name"] == "cilium"
        ),
        None,
    )
    assert cilium_kustomization, (
        f"no cilium Kustomization substituting cluster-config in {FLUX_KUSTOMIZATIONS_DIR}"
    )
    flux_manifests = build_flux_kustomization(
        cilium_kustomization, cluster_config_data, tmp_path
    )
    values_configmap = next(
        (
            manifest
            for manifest in flux_manifests
            if manifest["kind"] == "ConfigMap"
            and manifest["metadata"]["name"] == "cilium-values"
        ),
        None,
    )
    assert values_configmap, "flux build of cilium produced no cilium-values ConfigMap"
    flux_values = yaml.safe_load(values_configmap["data"]["values.yaml"])

    assert ansible_values == flux_values
