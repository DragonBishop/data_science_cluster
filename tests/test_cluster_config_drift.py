"""Tests that Flux resolves every cluster-config variable it uses."""

import subprocess
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
CLUSTER_CONFIG_DIR = REPO_ROOT / "infrastructure/cluster-config"
FLUX_KUSTOMIZATIONS_DIR = REPO_ROOT / "clusters/local"


def run_command(arguments: list[str]) -> str:
    """Run a command from the repo root and return its stdout, failing the test on a non-zero exit."""
    result = subprocess.run(
        arguments,
        cwd=REPO_ROOT,
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
