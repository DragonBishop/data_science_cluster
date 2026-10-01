"""Every ${VAR} in a Flux-substituted manifest must be defined in cluster-config.yaml."""

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
CLUSTER_CONFIG_PATH = REPO_ROOT / "infrastructure/cluster-config/cluster-config.yaml"
FLUX_KUSTOMIZATIONS_DIR = REPO_ROOT / "clusters/local"
# Skips Flux's $${VAR} escape
VARIABLE_REFERENCE = re.compile(r"(?<!\$)\$\{(\w+)\}")


def load_cluster_config_keys() -> set[str]:
    document = yaml.safe_load(CLUSTER_CONFIG_PATH.read_text())
    return set(document["data"])


def substitutes_cluster_config(document: dict | None) -> bool:
    if not document or document.get("kind") != "Kustomization":
        return False
    sources = document.get("spec", {}).get("postBuild", {}).get("substituteFrom", [])
    return any(
        source.get("kind") == "ConfigMap" and source.get("name") == "cluster-config"
        for source in sources
    )


def find_substituted_manifests() -> list[Path]:
    manifests: set[Path] = set()
    for kustomization_file in sorted(FLUX_KUSTOMIZATIONS_DIR.glob("*.yaml")):
        for document in yaml.safe_load_all(kustomization_file.read_text()):
            if not substitutes_cluster_config(document):
                continue
            manifest_dir = REPO_ROOT / document["spec"]["path"]
            if not manifest_dir.is_dir():
                raise FileNotFoundError(
                    f"{kustomization_file.name}: spec.path {manifest_dir} does not exist"
                )
            manifests.update(manifest_dir.rglob("*.yaml"))
    return sorted(manifests)


CLUSTER_CONFIG_KEYS = load_cluster_config_keys()
SUBSTITUTED_MANIFESTS = find_substituted_manifests()


def test_substituted_manifests_found():
    assert SUBSTITUTED_MANIFESTS, (
        f"no Kustomization in {FLUX_KUSTOMIZATIONS_DIR} substitutes from cluster-config"
    )


@pytest.mark.parametrize(
    "manifest",
    SUBSTITUTED_MANIFESTS,
    ids=lambda path: str(path.relative_to(REPO_ROOT)),
)
def test_variables_defined_in_cluster_config(manifest: Path):
    referenced_variables = set(VARIABLE_REFERENCE.findall(manifest.read_text()))
    undefined_variables = referenced_variables - CLUSTER_CONFIG_KEYS
    assert undefined_variables == set()
