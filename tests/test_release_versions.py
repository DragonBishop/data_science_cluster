"""Tests that every versioned file follows the cluster's release version."""

import json
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_collection_version_matches_the_cluster_release():
    """Check that the Ansible collection's galaxy.yml carries the cluster's release version."""
    cluster_version = json.loads(
        (REPO_ROOT / ".release-please-manifest.json").read_text()
    )["."]
    galaxy = yaml.safe_load(
        (
            REPO_ROOT / "ansible/ansible_collections/data_science/cluster/galaxy.yml"
        ).read_text()
    )
    assert galaxy["version"] == cluster_version, (
        f"galaxy.yml is {galaxy['version']}, the cluster is {cluster_version}; "
        "release-please-config.json's extra-files should keep them in step"
    )
