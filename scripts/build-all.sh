#!/usr/bin/env bash
# Build every BeeNote output, test it and pack it for release:
#   build/beenote       Linux (Wayland; Omarchy or any compositor)
#   build/beenote.exe   Windows 11
#   dist/beenote-<v>-linux-x86_64.tar.gz    the Linux binary and README
#   dist/beenote-<v>-windows-x86_64.zip     beenote.exe and README
#   dist/beenote-<v>-src.tar.gz             the sources (deploy-omarchy.sh
#                                           builds and installs from them)
#   dist/SHA256SUMS
# The Linux build is tested headless (tools/fakewl.py); the Windows one is
# run in the Windows VM when BeeNote's runner there is up (tools/winvm-run.sh),
# and skipped with a note when it is not.
#
#   scripts/build-all.sh             build, test, pack
#   scripts/build-all.sh --deploy    and install it into Omarchy
#   scripts/build-all.sh --no-test   skip the tests
#   scripts/build-all.sh --need-vm   fail, rather than skip, without the VM
#   scripts/build-all.sh --no-vm     skip the VM test (CI tests on Windows)
set -euo pipefail
cd "$(dirname "$0")/.."
test=1 deploy=0 need_vm=0 vm=1
while (($#)); do
    case $1 in
        --deploy) deploy=1 ;;
        --no-test) test=0 ;;
        --need-vm) need_vm=1 ;;
        --no-vm) vm=0 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-all: unknown option $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done
fail() { echo "build-all: $*" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < VERSION)"
manifest="$(jq -r .version omarchy-plugin/manifest.json)"
[[ "$manifest" == "$VERSION" ]] || fail "omarchy-plugin/manifest.json is $manifest, VERSION is $VERSION"

echo "==> Building v$VERSION"
scripts/build.sh release
[[ -f build/beenote.exe ]] || fail "no build/beenote.exe (ld needs the i386pep emulation)"
[[ "$(build/beenote --version)" == "BeeNote $VERSION" ]] || fail "build/beenote --version: $(build/beenote --version)"

if ((test)); then
    echo "==> Testing the Linux build (headless)"
    python3 tools/fakewl.py build/shots
    echo "==> Testing the Windows build (in the VM)"
    rc=0
    ((vm)) && { out=$(tools/winvm-run.sh --timeout 60 beenote.exe --version 2>&1) || rc=$?; }
    if ((!vm)); then
        echo "    skipped (--no-vm)"
    elif ((rc == 3)) && ((!need_vm)); then
        echo "    skipped: BeeNote's runner in the VM is not running"
    else
        ((rc == 0)) || fail "beenote.exe --version in the VM: rc=$rc: $out"
        out=$(tr -d '\r' <<<"$out")
        [[ "$out" == "BeeNote $VERSION" ]] || fail "beenote.exe --version in the VM: $out"
        echo "    $out"
    fi
fi

echo "==> Packing dist/"
rm -rf dist
mkdir -p dist/stage
lin="beenote-$VERSION-linux-x86_64" win="beenote-$VERSION-windows-x86_64" src="beenote-$VERSION-src"
mkdir dist/stage/"$lin" dist/stage/"$win"
cp build/beenote README.md dist/stage/"$lin"/
cp build/beenote.exe dist/stage/"$win"/
sed 's/$/\r/' README.md > dist/stage/"$win"/README.txt
tar -C dist/stage -czf dist/"$lin".tar.gz --owner=0 --group=0 "$lin"
(cd dist/stage && zip -qr ../"$win".zip "$win")
tar -czf dist/"$src".tar.gz --owner=0 --group=0 --transform "s|^|$src/|" \
    --exclude=__pycache__ VERSION README.md src scripts tools tests omarchy-plugin tui
rm -rf dist/stage
(cd dist && sha256sum ./*.tar.gz ./*.zip | sed 's| \./| |' > SHA256SUMS)
ls -l dist | tail -n +2 | awk '{printf "    %-44s %9s\n", $9, $5}'

if ((deploy)); then
    echo "==> Installing into Omarchy"
    scripts/deploy-omarchy.sh
fi
echo "BeeNote $VERSION: all outputs built."
