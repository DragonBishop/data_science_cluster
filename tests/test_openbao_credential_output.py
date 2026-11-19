"""Generated credentials survive provisioning failures without hiding the failure."""

import os
import subprocess
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK_DIR = REPO_ROOT / "ansible/ansible_collections/dragonbishop/cluster/playbooks"
PROVISIONING_TASK = (
    "Provision OpenBao and dependent services and report generated credentials"
)
CREDENTIALS = ["test-seal", "test-root", "test-recovery"]
FAILURE_MESSAGE = "simulated provisioning failure"

SEAL_KEY = {"openbao_effective_seal_key": "test-seal"}
GENERATED_SEAL_KEY = {"openbao_generated_seal_key": {"stdout": "test-seal"}}
INITIALIZED = {
    "openbao_root_token": "test-root",
    "openbao_fresh_recovery_keys": ["test-recovery"],
}


def provisioning_task() -> dict:
    """Return the playbook's provisioning block, whose always section prints the credentials."""
    playbook = yaml.safe_load((PLAYBOOK_DIR / "data_cluster.yml").read_text())
    matches = [
        task for task in playbook[0]["tasks"] if task["name"] == PROVISIONING_TASK
    ]
    assert len(matches) == 1, f"expected one task named {PROVISIONING_TASK!r}"
    return matches[0]


def write_test_playbook(tmp_path: Path, facts: dict, fail: bool) -> Path:
    """Write the real block/always task with its provisioning replaced by the given facts and outcome."""
    task = provisioning_task()
    task["block"] = [{"ansible.builtin.set_fact": facts}] if facts else []
    task["block"].append(
        {"ansible.builtin.fail": {"msg": FAILURE_MESSAGE}}
        if fail
        else {"ansible.builtin.debug": {"msg": "provisioning succeeded"}}
    )
    # import_tasks paths are relative to the real playbook
    for always_task in task["always"]:
        if "ansible.builtin.import_tasks" in always_task:
            always_task["ansible.builtin.import_tasks"] = str(
                PLAYBOOK_DIR / always_task["ansible.builtin.import_tasks"]
            )
    test_playbook = tmp_path / "provision.yml"
    test_playbook.write_text(
        yaml.safe_dump([{"hosts": "localhost", "gather_facts": False, "tasks": [task]}])
    )
    return test_playbook


def run_playbook(test_playbook: Path, tmp_path: Path) -> subprocess.CompletedProcess:
    """Run a playbook against localhost with Ansible's state kept in tmp_path."""
    return subprocess.run(
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


@pytest.mark.parametrize(
    ("facts", "fail", "printed"),
    [
        pytest.param(
            SEAL_KEY | INITIALIZED, False, CREDENTIALS, id="initialized-succeeds"
        ),
        pytest.param(SEAL_KEY | INITIALIZED, True, CREDENTIALS, id="initialized-fails"),
        pytest.param(
            SEAL_KEY | GENERATED_SEAL_KEY,
            True,
            ["test-seal"],
            id="seal-generated-fails",
        ),
        pytest.param({}, True, [], id="fails-before-openbao"),
    ],
)
def test_credentials_printed_after_provisioning(
    tmp_path: Path, facts: dict, fail: bool, printed: list[str]
):
    """The always section prints exactly the generated credentials, and a failure still fails the run."""
    result = run_playbook(write_test_playbook(tmp_path, facts, fail), tmp_path)
    output = result.stdout + result.stderr
    hidden = [credential for credential in CREDENTIALS if credential not in printed]

    assert result.returncode == (2 if fail else 0), output
    assert all(credential in output for credential in printed), output
    assert not any(credential in output for credential in hidden), output
    assert (FAILURE_MESSAGE in output) == fail, output
