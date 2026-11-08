"""Generated credentials survive provisioning failures without hiding the failure."""

import os
import subprocess
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK_DIR = REPO_ROOT / "ansible/ansible_collections/dragonbishop/cluster/playbooks"


@pytest.mark.parametrize(
    ("stage", "fail", "expected"),
    [
        ("initialized", False, ["test-seal", "test-root", "test-recovery"]),
        ("initialized", True, ["test-seal", "test-root", "test-recovery"]),
        ("seal-generated", True, ["test-seal"]),
        ("before-openbao", True, []),
    ],
)
def test_credentials_reported_after_provisioning(
    tmp_path: Path, stage: str, fail: bool, expected: list[str]
):
    # Use the production block/always structure and credential output tasks,
    # replacing only the provisioning work with a controlled success or failure.
    playbook = yaml.safe_load((PLAYBOOK_DIR / "data_cluster.yml").read_text())
    provisioning = playbook[0]["tasks"][0]
    facts = {}
    if stage != "before-openbao":
        facts["openbao_effective_seal_key"] = "test-seal"
    if stage == "seal-generated":
        facts["openbao_generated_seal_key"] = {"stdout": "test-seal"}
    if stage == "initialized":
        facts.update(
            openbao_root_token="test-root",
            openbao_fresh_recovery_keys=["test-recovery"],
        )
    provisioning["block"] = []
    if facts:
        provisioning["block"].append({"ansible.builtin.set_fact": facts})
    provisioning["block"].append(
        {"ansible.builtin.fail": {"msg": "simulated provisioning failure"}}
        if fail
        else {"ansible.builtin.debug": {"msg": "provisioning succeeded"}}
    )
    for task in provisioning["always"]:
        if "ansible.builtin.import_tasks" in task:
            task["ansible.builtin.import_tasks"] = str(
                PLAYBOOK_DIR / task["ansible.builtin.import_tasks"]
            )
    test_playbook = tmp_path / "provision.yml"
    test_playbook.write_text(
        yaml.safe_dump(
            [
                {
                    "hosts": "localhost",
                    "gather_facts": False,
                    "tasks": [provisioning],
                }
            ]
        )
    )
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", "-c", "local", str(test_playbook)],
        cwd=REPO_ROOT,
        env={
            **os.environ,
            "ANSIBLE_HOME": str(tmp_path / "ansible"),
            "ANSIBLE_LOCAL_TEMP": str(tmp_path / "ansible-tmp"),
            "ANSIBLE_NOCOLOR": "1",
        },
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == (2 if fail else 0), output
    for credential in ["test-seal", "test-root", "test-recovery"]:
        if credential in expected:
            assert credential in output, output
        else:
            assert credential not in output, output
    if fail:
        assert "simulated provisioning failure" in output, output
