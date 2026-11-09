#!/bin/bash
# cp-watch.sh <run-number>: run as root next to cp-run.sh. Every 2 s it snapshots the kext ring, the live RM allocation
# table (physical runs) and the PCIe DevCtl into ~/Library/Logs/nvmtl, so after a fabric panic (AMCC UNEXP_RT_HIT_DIR,
# whose ADDR is a physical address) the address can be matched to its owner:  grep -i <addr-prefix> allocs-N.txt
# Stop with Ctrl-C. Use `sudo -E` so $HOME stays the user's.
set -u
N=${1:?run number}; LOGD=${HOME}/Library/Logs/nvmtl; mkdir -p "$LOGD"
C="$(cd "$(dirname "$0")" && pwd)/../../out/nvrmctl"; [ -x "$C" ] || C="$HOME/Desktop/nvidia-macos-driver-arm64/nvrmctl"
# 0.308.1139+ lists the allocations without root; on an older kext the nvdev sudoers file (unattended/) lets
# `sudo -n` do it, and without either the allocs snapshot is simply empty
A=("$C"); if ! "$C" allocs > /dev/null 2>&1 && sudo -n "$HOME/Desktop/nvidia-macos-driver-arm64/nvrmctl" devctl > /dev/null 2>&1; then A=(sudo -n "$HOME/Desktop/nvidia-macos-driver-arm64/nvrmctl"); fi
echo "watching into $LOGD/{ring,allocs,devctl}-$N.txt with $C (Ctrl-C stops)"
: > "$LOGD/devctl-$N.txt"
while :; do
  "$C" log > "$LOGD/ring-$N.tmp" 2>/dev/null && mv "$LOGD/ring-$N.tmp" "$LOGD/ring-$N.txt"
  "${A[@]}" allocs > "$LOGD/allocs-$N.tmp" 2>/dev/null && mv "$LOGD/allocs-$N.tmp" "$LOGD/allocs-$N.txt"
  echo "$(date +%T) $("$C" devctl 2>&1)" >> "$LOGD/devctl-$N.txt"
  sleep 2
done
