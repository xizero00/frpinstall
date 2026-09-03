#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/../frpinstall" uninstall-frps
bash "${SCRIPT_DIR}/../frpinstall" install-frps
