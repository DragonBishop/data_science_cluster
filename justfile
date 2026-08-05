module_name := "clusterpgis"

# list commands
default:
  @just --list

# install the packages
install:
  {{if path_exists("uv.lock") != "true" {"uv sync --all-groups --all-extras --inexact"} else {"uv sync --all-groups --all-extras --locked --inexact"} }}

# setup for development
setup: install git-setup

# run test coverage and create
test-cov:
  uv run pytest --cov=src/clusterpgis --cov-report=lcov:lcov.info --cov-report=term-missing --cov-report html --cov-report xml

# update packages and uv lock file
update:
  uv sync -U --all-groups --all-extras --inexact

# set up the nbwipers git filter so notebooks stay clean on commit
git-setup: install
  @if [ ! -d .git ]; then git init; fi
  uv run nbwipers install local