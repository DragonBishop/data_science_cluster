"""Pytest hooks shared by the whole test suite."""

import shutil

import pytest

REQUIRED_TOOLS = ["kubectl", "flux", "ansible", "ansible-playbook"]


def pytest_sessionstart(session: pytest.Session):
    """Exit before collection if a required tool is missing."""
    missing_tools = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing_tools:
        pytest.exit(
            f"{', '.join(missing_tools)} not found. See INSTALLATION.md Requirements.",
            returncode=pytest.ExitCode.USAGE_ERROR,
        )
