#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/../frpinstall" uninstall-frpc
bash "${SCRIPT_DIR}/../frpinstall" install-frpc
