#!/bin/bash
# rebuild_all.sh: RM (incremental) -> NVRM.kext -> package -> ~/Desktop/nvidia-macos-driver-arm64 with a fresh SHA256SUMS.
# Stops on the first RM compile error (a stale object would otherwise be linked into the kext).
cd "$(dirname "$0")/../.." || exit 1
LOG=${RM_BUILD_LOG:-/tmp/claude-501/build_rm.log}; mkdir -p "$(dirname "$LOG")"
echo "== build_rm $(date +%T)"; bash build/arm64/build_rm.sh > "$LOG" 2>&1; tail -3 "$LOG"
grep -q "error:" "$LOG" && { echo "RM BUILD HAD ERRORS"; grep -m5 "error:" "$LOG"; exit 1; }
echo "== build_nvrm $(date +%T)"; bash build/arm64/build_nvrm.sh 2>&1 | tail -2 || exit 1
echo "== package $(date +%T)"; bash build/arm64/package.sh 2>&1 | tail -1 || exit 1
D=~/nvdev/pkg
rsync -a --delete out/package-arm64/Library/ "$D/Library/" && rsync -a out/package-arm64/Users/ "$D/Users/" && cp out/package-arm64/install.sh out/package-arm64/uninstall.sh out/package-arm64/VERSION out/package-arm64/nullmoth-runtime-check.sh "$D/" && cp out/rendersim/argsim "$D/argsim" 2>/dev/null
(cd "$D" && find . -type f ! -name SHA256SUMS ! -name .DS_Store -exec shasum -a 256 '{}' \; | sed 's|  \./|  |' | sort -k2 > SHA256SUMS && shasum -a 256 --strict -c SHA256SUMS --quiet && echo "manifest OK")
echo "NVRM version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$D/Library/Extensions/NVRM.kext/Contents/Info.plist")"
echo "== done $(date +%T)"
