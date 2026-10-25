#!/usr/bin/env bash
# Run a command in the Windows 11 VM (omarchy-windows-vm) and give back its
# output and exit code, through the folder the VM shares (~/Windows, which
# the guest sees as \\host.lan\Data). BeeNote has its own job runner there,
# in ~/Windows/beenote-run, apart from BeeModel's bee-run (never touch
# that one): tools/winvm/runner/runner.ps1 copies beenote-run\bin\ to
# C:\beenote-run and runs <id>.cmd there with cmd.exe. This script
# publishes the runner (setup.ps1, boot.ps1, runner-<hash>.ps1) and takes
# build/beenote.exe and tools/winvm/*.ps1 (the test drivers) along:
#   tools/winvm-run.sh beenote.exe --version
#   tools/winvm-run.sh --timeout 300 powershell -ExecutionPolicy Bypass -File ui-test.ps1
# The command is a cmd.exe line. BEE_WINVM_SHARE overrides ~/Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
TIMEOUT=120
if [[ "${1:-}" == --timeout ]]; then TIMEOUT=$2; shift 2; fi
[[ $# -gt 0 ]] || { echo "usage: tools/winvm-run.sh [--timeout s] <command line>" >&2; exit 2; }
SHARE="${BEE_WINVM_SHARE:-$HOME/Windows}/beenote-run"
mkdir -p "$SHARE/bin"

# Publish the runner: a new name for every version (see runner.ps1).
cp tools/winvm/runner/setup.ps1 tools/winvm/runner/boot.ps1 "$SHARE/"
runner="runner-$(sha256sum tools/winvm/runner/runner.ps1 | cut -c1-8).ps1"
if [[ ! -f "$SHARE/$runner" ]]; then
    cp tools/winvm/runner/runner.ps1 "$SHARE/$runner.tmp"
    mv "$SHARE/$runner.tmp" "$SHARE/$runner"
    for old in "$SHARE"/runner-*.ps1; do
        [[ "$old" == "$SHARE/$runner" ]] || rm -f "$old"
    done
fi

alive="$SHARE/runner.alive"
if [[ ! -f "$alive" ]] || (( $(date +%s) - $(stat -c %Y "$alive") > 10 )); then
    cat >&2 <<'MSG'
winvm-run: BeeNote's runner in the VM is not running. Start the VM
(omarchy-windows-vm launch) and, the first time only, run this in an
administrator PowerShell in it:
  powershell -ExecutionPolicy Bypass -File \\host.lan\Data\beenote-run\setup.ps1
MSG
    exit 3
fi
[[ -f build/beenote.exe ]] && cp build/beenote.exe "$SHARE/bin/"
compgen -G 'tools/winvm/*.ps1' >/dev/null && cp tools/winvm/*.ps1 "$SHARE/bin/"
id="job$(date +%s%N)"
echo "$TIMEOUT" > "$SHARE/$id.limit"
printf '@echo off\r\n%s\r\nexit /b %%errorlevel%%\r\n' "$*" > "$SHARE/$id.tmp"
mv "$SHARE/$id.tmp" "$SHARE/$id.cmd"
end=$((SECONDS + TIMEOUT + 30))
until [[ -f "$SHARE/$id.rc" ]]; do
    if (( SECONDS >= end )); then
        echo "winvm-run: no answer in ${TIMEOUT} s (see $SHARE/runner.log)" >&2
        rm -f "$SHARE/$id.cmd" "$SHARE/$id.limit"
        exit 124
    fi
    sleep 0.3
done
sleep 0.2
cat "$SHARE/$id.out" 2>/dev/null || true
rc=$(tr -dc '0-9-' < "$SHARE/$id.rc")
rm -f "$SHARE/$id.out" "$SHARE/$id.rc"
exit "${rc:-1}"
