#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/../frpinstall.sh" unins_frps_s
bash "${SCRIPT_DIR}/../frpinstall.sh" ins_frps_s
