#!/bin/bash
# Installer for the repower (power-loss recovery) Klipper plugin.
# Symlinks repower.py into klippy/extras so `git pull` keeps it updated, and
# reminds you to include repower.cfg.
set -e

KLIPPER_PATH="${KLIPPER_PATH:-${HOME}/klipper}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ ! -d "${KLIPPER_PATH}/klippy/extras" ]; then
    echo "ERROR: Klipper not found at ${KLIPPER_PATH}"
    echo "Set KLIPPER_PATH=/path/to/klipper and re-run."
    exit 1
fi

echo "Linking repower.py -> ${KLIPPER_PATH}/klippy/extras/repower.py"
ln -sf "${SCRIPT_DIR}/repower.py" "${KLIPPER_PATH}/klippy/extras/repower.py"

echo
echo "Done. Next steps:"
echo "  1) Add to printer.cfg:        [include repower.cfg]"
echo "     (copy or symlink repower.cfg into your config directory)"
echo "  2) Ensure [force_move] has:   enable_force_move: True"
echo "  3) Restart the Klipper host service."
