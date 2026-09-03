#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/../frpinstall.sh" uninstall-frpc
bash "${SCRIPT_DIR}/../frpinstall.sh" install-frpc
