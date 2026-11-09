#!/bin/bash
set -u
# runs as root: tools resolve through a fixed PATH, never one the caller exported
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = --payload ]; then
  [ "$#" = 2 ] && [ -d "$2" ] || { echo "STOP: --payload requires an existing package directory" >&2; exit 2; }
  HERE=$(cd "$2" && pwd) || exit 2
elif [ "$#" != 0 ]; then echo "STOP: expected --payload directory or no arguments" >&2; exit 2; fi
# One script for both Macs: ARCH picks the kext set, the kernel-collection arguments and the steps that differ, and every
# x86_64 line is the one that shipped. Apple Silicon (docs/ARM64-PORT-NOTES.md): the card renders and Apple's own display
# shows the result (the accelerator's headless mode), so NVRMFB, NVRMAGDC and the primary-GPU selector, which exist to
# drive a display on the card, are never installed there, and NVAccelArm (kexts/NVAccelArm) stands in for NVAccel.
ARCH=$(uname -m)
case $ARCH in
  arm64) KEXTS="NVRM NVAccelArm"; KARCH=arm64e; KEXTS_WORD=both;;
  *) KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"; KARCH=x86_64; KEXTS_WORD="all four";;
esac
EXT=/Library/Extensions; GB=/Library/GPUBundles; FW=/Library/NullMoth/nvfw; FWOLD=/Users/Shared/nvfw
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
K=/System/Library/Kernels/kernel
if [ "$ARCH" = arm64 ]; then
  # /System/Library/Kernels/kernel is the x86_64 image even on an Apple Silicon Mac (measured, macOS 27); the kernel that
  # runs is the per-chip one kern.version names (RELEASE_ARM64_T6000 -> kernel.release.t6000). Nothing else about the KDK
  # changes: there is none, and --allow-missing-kdk stays.
  chip=$(sysctl -n kern.version 2>/dev/null | sed -nE 's/.*RELEASE_ARM64_([A-Za-z0-9]+).*/\1/p' | tr '[:upper:]' '[:lower:]')
  K=""; [ -z "$chip" ] || K="/System/Library/Kernels/kernel.release.$chip"
fi
# macOS 13+ kmutil refuses to build any kernel collection without a Kernel Debug Kit matching the build unless it is told
# --allow-missing-kdk. The auxiliary collection only links against the boot and system collections already on disk.
KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
KB=/System/Library/KernelCollections/BootKernelExtensions.kc
KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
if [ "$ARCH" = arm64 ]; then
  # Apple Silicon has no /System/Library/KernelCollections: the kernel, the boot kexts and the system kexts are one file,
  # the Preboot kernelcache, and kmutil inspect names it. The auxiliary build links against that file as both collections.
  KB=$(kmutil inspect -a arm64e 2>/dev/null | sed -nE 's/^boot kernel collection at (.*) \([0-9A-Fa-f-]+\):$/\1/p' | head -1)
  KS=$KB
fi
BK=""; LOCKDIR=/Library/NullMoth/install.lock; LOCK_HELD=0; LOCK_RELEASE_OK=1; LOCK_ID=""
INSTALLING=0; NEWKC=""; STAGE=""
release_install_lock() {
  if [ "$LOCK_HELD" = 1 ] && [ "$LOCK_RELEASE_OK" = 1 ]; then
    if [ -z "$LOCK_ID" ] || [ -L "$LOCKDIR" ] || [ ! -d "$LOCKDIR" ] ||
       [ "$(stat -f '%d:%i' "$LOCKDIR" 2>/dev/null)" != "$LOCK_ID" ]; then
      echo "   NOTE: installer guard identity changed; its current path is retained for review." >&2
      return
    fi
    rm -f "$LOCKDIR/owner" "$LOCKDIR/installing"
    rmdir "$LOCKDIR" || echo "   NOTE: installer lock could not be released; review it before another install." >&2
    LOCK_HELD=0
  elif [ "$LOCK_HELD" = 1 ]; then
    echo "   NOTE: installer guard retained because restoration was incomplete; recovery review is required." >&2
  fi
}

rollback_install() {
  local failed=0 k b restore_kexts="$KEXTS"
  # A later process recovering a stale guard has not detected PRIMARY yet.
  if [ -f "$BK/primary-selector-used" ]; then
    case " $restore_kexts " in *' NVPrimarySelector '*) ;; *) restore_kexts="$restore_kexts NVPrimarySelector";; esac
  fi
  [ -z "$NEWKC" ] || rm -f "$NEWKC" || failed=1
  for k in $restore_kexts; do
    rm -rf "$EXT/$k.kext" || failed=1
    [ ! -e "$BK/$k.kext" ] || ditto "$BK/$k.kext" "$EXT/$k.kext" || failed=1
  done
  for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do
    rm -rf "$GB/$b" || failed=1
    [ ! -e "$BK/$b" ] || ditto "$BK/$b" "$GB/$b" || failed=1
  done
  rm -rf /Library/NullMoth/kexts "$FW" || failed=1
  [ ! -d "$BK/kexts" ] || ditto "$BK/kexts" /Library/NullMoth/kexts || failed=1
  # Restore the firmware to both locations: a driver older than this one looks for it in /Users/Shared,
  # and root writing that directory is harmless (root-owned, inside a sticky parent).
  [ ! -d "$BK/nvfw" ] || ditto "$BK/nvfw" "$FW" || failed=1
  [ ! -d "$BK/nvfw" ] || { mkdir -p "$FWOLD" && ditto "$BK/nvfw" "$FWOLD"; } || failed=1
  if [ -f "$BK/AuxiliaryKernelExtensions.kc" ]; then cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC" || failed=1
  else rm -f "$KC" || failed=1; fi
  if [ -f "$BK/os-major" ]; then cp -p "$BK/os-major" /Library/NullMoth/os-major || failed=1
  else rm -f /Library/NullMoth/os-major || failed=1; fi
  # the version record follows the files it describes, or Send logs names a version that is not installed
  if [ -f "$BK/driver-version" ]; then cp -p "$BK/driver-version" /Library/NullMoth/driver-version || failed=1
  else rm -f /Library/NullMoth/driver-version || failed=1; fi
  return "$failed"
}
step() { echo; echo "== $*"; }; ok() { echo "   ok  $*"; }
boot_sec() { sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+),.*/\1/'; }
# kern.boottime is derived from the clock and moves when the clock is corrected after boot, so "the same boot" allows
# 60 s of drift (review: an exact match could take a live install for a dead one and roll its files back mid-install).
same_boot() { local a=$1 b; b=$(boot_sec); [ -n "$a" ] && [ -n "$b" ] && [ $((a > b ? a - b : b - a)) -le 60 ]; }
# the pid is still the installer (pid numbers are reused): its command line names this script
is_installer_pid() { ps -o command= -p "$1" 2>/dev/null | grep -Eq '(nullmoth-install|/install)\.sh'; }
# A guard left by an install that was killed outright (power loss, a forced quit, a restart mid-install) stopped every
# later install with "installer guard already exists" until someone removed it by hand (3 reports and chat, 10-12).
# The guard now records its owner (pid, boot) and, once files start changing, the backup it can be restored from.
# A guard whose owner is gone is recovered: rolled back from that backup if it had started changing files, then cleared.
# A live install, or one whose own restore failed (restore-incomplete), still stops.
recover_stale_guard() {
  local g=$LOCKDIR o=$LOCKDIR/owner pid="" boot="" bk=""
  [ -d "$g" ] && [ ! -L "$g" ] && [ "$(stat -f '%u' "$g" 2>/dev/null)" = 0 ] || return 0
  [ ! -e "$g/restore-incomplete" ] || die "the last install could not restore the previous driver (its backup is kept in /Library/NullMoth); use Remove NVIDIA driver, then install again, or send logs (no driver changes made)"
  if [ -f "$o" ] && [ ! -L "$o" ]; then
    pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$o" | head -1); boot=$(sed -n 's/^boot=\([0-9][0-9]*\)$/\1/p' "$o" | head -1)
    bk=$(sed -n 's/^bk=\(.*\)$/\1/p' "$o" | head -1)
    if [ -n "$pid" ] && same_boot "$boot" && kill -0 "$pid" 2>/dev/null && is_installer_pid "$pid"; then return 0; fi
  else
    # a guard from 1.14.7 or earlier has no owner record: an install cannot outlive a restart, so one older than this boot is stale
    [ "$(stat -f '%m' "$g" 2>/dev/null || echo 0)" -lt $(( $(boot_sec) - 60 )) ] || return 0
  fi
  echo "   NOTE: an earlier install was interrupted and left its guard behind; recovering it"
  if [ -e "$g/installing" ]; then
    case "$bk" in /Library/NullMoth/backup-*) ;; *) die "an interrupted install had changed driver files and its backup is not recorded; use Remove NVIDIA driver, then install again (no driver changes made)";; esac
    [ -d "$bk" ] && [ ! -L "$bk" ] || die "the interrupted install's backup $bk is missing; use Remove NVIDIA driver, then install again (no driver changes made)"
    BK=$bk
    if ! rollback_install; then : > "$g/restore-incomplete"; die "restoring the interrupted install failed; its backup is kept at $bk"; fi
    echo "   ok  the interrupted install was rolled back from $bk"; BK=""
  fi
  rm -f "$o" "$g/installing"; rmdir "$g" 2>/dev/null || die "could not clear the interrupted install's guard"
}
die() {
  echo "   STOP: $*" >&2
  if [ "$INSTALLING" = 1 ]; then
    if rollback_install; then echo "   Previous installation restored; backup retained at $BK." >&2
    else LOCK_RELEASE_OK=0; : > "$LOCKDIR/restore-incomplete" 2>/dev/null; echo "   Restore incomplete; recovery files remain at $BK." >&2; fi
  fi
  exit 1
}

# Keep diagnostic output bounded while retaining the copy command's exit status.
backup_copy() {
  local component=$1; shift
  "$@" 2>&1 | tail -c 4096 > "$T/backup-error.log"
  local status=("${PIPESTATUS[@]}")
  if [ "${status[0]}" != 0 ] || [ "${status[1]}" != 0 ]; then
    printf '   BACKUP-DIAGNOSTIC component=%s command-status=%s capture-status=%s stderr-tail-limit=4096\n' "$component" "${status[0]}" "${status[1]}" >&2
    [ ! -f "$T/backup-error.log" ] || cat "$T/backup-error.log" >&2
    echo >&2
    die "back up $component"
  fi
}
# Apple Silicon only. Third-party kexts load there only under a boot security policy the owner set in recoveryOS, and
# the first load of each kext also needs an approval in System Settings and a restart. The install reads the policy up
# front (bputil -d prints the LocalPolicy, root only; csrutil status says whether kext signatures are still checked)
# and stops with the way out, instead of ending in kernelmanagerd's one-line refusal. Nothing here changes the policy:
# it cannot be changed from macOS. These kexts carry no Developer ID signature, so the Reduced Security box ("Allow user
# management of kernel extensions from identified developers") alone does not admit them; csrutil disable in recoveryOS
# sets Permissive Security and switches that signature check off in one step.
ARM64_POLICY_HELP='   Restart holding the power button until "Options" appears, open Utilities > Terminal and run
      csrutil disable
   (Permissive Security: unsigned kernel extensions and boot-args allowed), then restart into macOS and install again.
   Startup Security Utility > Reduced Security with "Allow user management of kernel extensions" admits only kexts signed
   with a Developer ID, which these are not.'
ARM64_APPROVE=0
arm64_policy() {
  local pol mode kexts sip signed=1 k vg
  # A Mac with more than one macOS installed makes bputil -d ask which one to show (this Mac has two), so the running
  # volume group is named and its input is closed; a bputil that still asks gets EOF and the policy stays unread.
  vg=$(diskutil info / 2>/dev/null | sed -n 's/^ *APFS Volume Group: *//p' | head -1)
  pol=$(bputil -d ${vg:+-v "$vg"} </dev/null 2>/dev/null) || pol=""
  mode=$(printf '%s\n' "$pol" | grep -i -m1 'security mode' | sed 's/^[^:]*: *//')
  kexts=$(printf '%s\n' "$pol" | grep -i -m1 'kext' | sed 's/^[^:]*: *//')
  sip=$(csrutil status 2>/dev/null)
  for k in $KEXTS; do codesign -dvv "$(kpath "$k")" 2>&1 | grep -q '^Authority=' || signed=0; done
  case "$mode" in
    *[Pp]ermissive*) ok "boot policy: $mode";;
    *[Ff]ull*) die "boot policy is Full Security: macOS loads no third-party kernel extensions (no changes made)
$ARM64_POLICY_HELP";;
    *[Rr]educed*)
      case "$kexts" in
        *[Ee]nabled*|*[Aa]llowed*) ok "boot policy: $mode, user kernel extensions allowed";;
        *) die "boot policy is Reduced Security without user kernel extensions (no changes made)
$ARM64_POLICY_HELP";;
      esac;;
    "") echo "   note: the boot policy could not be read (bputil -d); kernelmanagerd decides below";;
    *) echo "   note: boot policy \"$mode\" not recognised; kernelmanagerd decides below";;
  esac
  if [ "$signed" = 0 ] && { printf '%s\n' "$sip" | grep -q 'status: enabled\.' || printf '%s\n' "$sip" | grep -qi 'Kext Signing: enabled'; }; then
    die "System Integrity Protection still checks kernel-extension signatures, and these kexts have no Developer ID (no changes made)
$ARM64_POLICY_HELP"
  fi
  [ "$signed" = 1 ] || echo "   note: the kexts are unsigned or ad-hoc signed; macOS admits them only under Permissive Security"
}
# <kmutil log>: the policy explanation when kmutil's refusal reads like one, or nothing (on x86_64 always nothing)
arm64_kmutil_hint() {
  [ "${ARCH:-}" = arm64 ] || return 0
  grep -qiE 'not approved|not allowed|not permitted|security mode|policy|permissive|reduced security|signature|untrusted|rejected' "$1" 2>/dev/null || return 0
  printf '%s\n%s\n' "macOS refused the kernel extensions under the current boot security policy:" "$ARM64_POLICY_HELP"
}
# Apple Silicon: the auxiliary collection is not a file this script writes. kernelmanagerd builds it in the Preboot
# volume and the Secure Enclave signs its hash into the LocalPolicy, so the way in is a load request for each kext:
# kernelmanagerd stages and checks it; on a first install macOS answers "not approved" and shows the notice that sends
# the user to System Settings > Privacy & Security, and the collection is built after the approval and a restart. A kext
# already allowed is rebuilt into the collection now (and may start before the restart; the fallback job below treats
# that like any other start).
arm64_stage_kexts() {
  local k log hint
  for k in $KEXTS; do
    log="$T/kmload-$k.log"
    if kmutil load -p "$EXT/$k.kext" >"$log" 2>&1; then ok "$k accepted by kernelmanagerd"; continue; fi
    if grep -qiE 'not approved|approv' "$log"; then
      ARM64_APPROVE=1; echo "   $k: waiting for your approval in System Settings > Privacy & Security"; continue
    fi
    tail -20 "$log"
    hint=$(arm64_kmutil_hint "$log")
    [ -z "$hint" ] || die "kernelmanagerd refused $k (restore from $BK)
$hint"
    echo "   NOTE: kmutil load $k failed (log above); the restart decides whether the collection was rebuilt"
  done
}
finish_install() { [ -z "$STAGE" ] || rm -rf "$STAGE"; release_install_lock; }
trap finish_install EXIT
trap 'die "installer interrupted (signal HUP)"' HUP
trap 'die "installer interrupted (signal INT)"' INT
trap 'die "installer interrupted (signal TERM)"' TERM

[ "$(id -u)" -eq 0 ] || die "run with sudo"
step "1. this Mac"
case $ARCH in x86_64|arm64) ;; *) die "Intel/x86_64 or Apple Silicon/arm64 only (this is $ARCH)";; esac
v=$(sw_vers -productVersion); MAJ=${v%%.*}
BUILD=$(sw_vers -buildVersion)
printf '%s\n' "$BUILD" | grep -Eq '^[0-9]+[A-Za-z][A-Za-z0-9]+$' || die "cannot identify the current macOS build"
if [ "$ARCH" = x86_64 ]; then
  case $MAJ in 15|26) ;; *) die "This driver is built for macOS 15 and 26 (this is $v); no changes made";; esac
  # NVAccel is the one kext built per macOS: Tahoe made the IOAcceleratorFamily2 methods it inherits private (see
  # kexts/NVRM/accel/gen_tahoe_fwd.py). The other three kexts are the same binaries on 15 and 26.
  VAR="$HERE/Library/NullMoth/kexts/$MAJ"; [ -d "$VAR/NVAccel.kext" ] || die "this package has no NVAccel for macOS $MAJ"
else
  # The Apple Silicon kexts were linked against the macOS 27 kernel collection (every imported symbol checked, see
  # docs/ARM64-PORT-NOTES.md); 26 is admitted because the test build in step 3 is the real check of those symbols.
  case $MAJ in 26|27) ;; *) die "The Apple Silicon build is for macOS 26 and 27 (this is $v); no changes made";; esac
  [ -n "$KB" ] && [ -f "$KB" ] || die "cannot find this Mac's kernel collection (kmutil inspect -a arm64e named none); no changes made"
  VAR=""   # no per-macOS accelerator: NVAccelArm uses only IOGraphicsFamily's public IOAccelerator
  for k in $KEXTS; do [ -d "$HERE/Library/Extensions/$k.kext" ] || die "this package has no $k.kext built for Apple Silicon (arm64e)"; done
fi
kpath() {
  case "$1" in
    NVAccel) echo "$VAR/NVAccel.kext";;
    NVPrimarySelector) echo "$SELECTOR_SOURCE";;
    *) echo "$HERE/Library/Extensions/$1.kext";;
  esac
}
# On Apple Silicon the card is a hot-plugged eGPU, and a driver that panics on plug cannot be replaced while it is
# plugged in: NOGPU=1 installs without the card present (the kexts match it the next time it is plugged in).
if [ "$ARCH" = arm64 ] && [ "${NOGPU:-0}" = 1 ]; then echo "   note: NOGPU=1, not checking for the card (plug the eGPU in after the restart)"
else ioreg -r -c IOPCIDevice -d 1 | grep -q '"vendor-id" = <de100000>' || die "no NVIDIA GPU found on PCI${ARCH:+ (arm64: NOGPU=1 installs with the eGPU unplugged)}"; fi
# The driver runs the cards NVIDIA's GSP firmware supports (Turing and later). The same list the Windows builder uses
# (open-gpu-kernel-modules 615.78.08, p1401/nvidia_gsp_ids.json). Installing it for an older card (GTX 10 and before)
# would switch the firmware screen off and leave nothing to draw: those PCs run macOS in basic display instead.
SUPPORTED_IDS="
1E02 1E04 1E07 1E30 1E36 1E78 1E81 1E82 1E84 1E87 1E89 1E90 1E91 1E93 1EB0 1EB1 1EB5 1EB6 1EC2 1EC7 1ED0 1ED1 1ED3
1EF5 1F02 1F03 1F06 1F07 1F08 1F0A 1F10 1F11 1F12 1F14 1F15 1F36 1F42 1F47 1F50 1F51 1F54 1F55 1F76 1F82 1F83 1F91
1F95 1F96 1F97 1F98 1F99 1F9C 1F9D 1F9F 1FA0 1FB0 1FB1 1FB2 1FB6 1FB7 1FB8 1FB9 1FBA 1FBB 1FBC 1FDD 1FF0 1FF2 1FF9
2182 2184 2187 2188 2191 2192 21C4 21D1 2203 2204 2206 2207 2208 220A 2216 2230 2231 2232 2233 2414 2420 2438 2460
2482 2484 2486 2487 2488 2489 249C 249D 24A0 24B0 24B1 24B6 24B7 24B8 24B9 24BA 24BB 24C7 24C9 24DC 24DD 24E0 24FA
2503 2504 2507 2508 2520 2521 2523 2531 2544 2560 2563 2571 2582 2584 25A0 25A2 25A5 25A6 25A7 25A9 25AA 25AB 25AC
25AD 25B0 25B2 25B8 25B9 25BA 25BB 25BC 25BD 25E0 25E2 25E5 25EC 25ED 25F9 25FA 25FB 2684 2685 2689 26B1 26B2 26B3
2702 2704 2705 2709 2717 2730 2757 2770 2782 2783 2786 2788 27A0 27B0 27B1 27B2 27BA 27BB 27E0 27FB 2803 2805 2808
2820 2822 2838 2860 2882 28A0 28A1 28A3 28B0 28B8 28B9 28BA 28BB 28E0 28E1 28E3 28F8 2B85 2B87 2B8C 2BB1 2BB3 2BB4
2BB5 2BB9 2C02 2C05 2C09 2C18 2C19 2C31 2C33 2C34 2C38 2C39 2C3A 2C58 2C59 2C77 2C79 2D04 2D05 2D18 2D19 2D30 2D39
2D58 2D59 2D79 2D83 2D98 2DB8 2DB9 2DD8 2DF9 2E03 2E06 2E12 2F04 2F06 2F18 2F38 2F58
"
NV_IDS=$(ioreg -r -c IOPCIDevice -d 1 | awk '/"vendor-id" = <de100000>/{nv=1} /"device-id" = </{ if (match($0, /<[0-9a-f]+>/)) d=substr($0, RSTART+1, 4) }
  /^\+-o|^ *\}/{ if (nv && d != "") print toupper(substr(d,3,2) substr(d,1,2)); nv=0; d="" }' | sort -u)
CARD=""; for i in $NV_IDS; do case " $(echo $SUPPORTED_IDS) " in *" $i "*) CARD=$i;; esac; done
# Every device id from 1E00 up is Turing or newer (TU102 is 1E02; Volta and older sit below it), which RM drives through GSP.
# The list above names the GeForce/RTX ids measured so far; a Quadro T1200 laptop (1FBC) was refused as "older".
[ -n "$CARD" ] || for i in $NV_IDS; do case $i in *[!0-9A-F]*|"") ;; *) [ $((16#$i)) -ge $((16#1E00)) ] && CARD=$i;; esac; done
if [ "$ARCH" = arm64 ] && [ "${NOGPU:-0}" = 1 ] && [ -z "$NV_IDS" ]; then CARD=nogpu; ok "macOS $v, $ARCH, installing without the card (NOGPU=1)"
else
[ -n "$CARD" ] || die "this NVIDIA card (device $(echo $NV_IDS)) is older than the driver supports (RTX 20 / Turing and newer); macOS keeps running on it in basic display, with no changes made"
ok "macOS $v, $ARCH, NVIDIA GPU present"
fi
[ "$ARCH" != arm64 ] || arm64_policy

step "2. package integrity"
# The extracted package is usually writable by the logged-in user, so a process running as that user could swap a kext
# between this check and the copy into /Library/Extensions. Check and install a root-owned private copy instead.
SELF=$(cd "$(dirname "$0")" && pwd)
STAGE=$(mktemp -d /var/tmp/nullmoth-package.XXXXXX) && [ -n "$STAGE" ] && [ -d "$STAGE" ] || die "create private package copy"
cp -cR "$HERE" "$STAGE/pkgroot" 2>/dev/null || { rm -rf "$STAGE/pkgroot"; ditto "$HERE" "$STAGE/pkgroot"; } && chown -R root:wheel "$STAGE" && chmod -R go-w "$STAGE" || die "copy package to $STAGE"
# shasum follows links: a link to an identical file outside the copy passes the check and can still change later.
while IFS= read -r -d '' link; do
  case "$(readlink "$link")" in /*|..|../*|*/..|*/../*) die "package holds a link that leaves the package: ${link#"$STAGE/pkgroot/"}";; esac
done < <(find "$STAGE/pkgroot" -type l -print0)
[ "$SELF" = "$HERE" ] && SELF="$STAGE/pkgroot"
HERE="$STAGE/pkgroot"
# VAR was set from the original folder before this step, and kpath reads the accelerator kext through it. Point it
# at the private copy too, or that one kernel extension is still taken from the folder the check no longer covers.
VAR="$HERE/Library/NullMoth/kexts/$MAJ"
# --strict: without it shasum skips a malformed line and still reports success
(cd "$HERE" && shasum -a 256 --strict -c SHA256SUMS --quiet) || die "SHA256SUMS mismatch: re-download the package"
for target in 15 26; do
  [ "$ARCH" = x86_64 ] || continue   # the per-macOS accelerator is an x86 kext; Apple Silicon ships one build of each kext
  [ -f "$HERE/Library/NullMoth/kexts/$target/NVAccel.kext/Contents/MacOS/NVAccel" ] && \
    [ -f "$HERE/Library/NullMoth/kexts/$target/NVAccel.kext/Contents/Info.plist" ] || die "this package lacks the complete macOS $target accelerator"
done
if [ "$ARCH" = x86_64 ]; then ok "every file matches SHA256SUMS and both OS accelerators are present"
else
  for k in $KEXTS; do
    [ -f "$HERE/Library/Extensions/$k.kext/Contents/MacOS/$k" ] && [ -f "$HERE/Library/Extensions/$k.kext/Contents/Info.plist" ] || die "this package lacks the complete $k kext"
  done
  ok "every file matches SHA256SUMS and both Apple Silicon kexts are present"
fi
RUNTIME_PREFLIGHT="$SELF/nullmoth-runtime-check.sh"
[ -x "$RUNTIME_PREFLIGHT" ] || die "runtime compatibility checker is missing"
/bin/bash "$RUNTIME_PREFLIGHT" "$HERE" "$v" || die "userland runtime cannot load on this macOS version"

require_install_directory() {
  local metadata permissions entry listing grants
  [ ! -L "$1" ] && [ -d "$1" ] || die "installer parent must be a real directory (no driver changes made)"
  metadata=$(stat -f '%u %Lp' "$1" 2>/dev/null) || die "cannot verify installer parent ownership"
  case "$metadata" in
    "0 "[0-7][0-7][0-7]|"0 "[0-7][0-7][0-7][0-7]) ;;
    *) die "installer parent is not a verified root-owned directory (no driver changes made)";;
  esac
  permissions=${metadata#* }
  [ $((8#$permissions & 022)) -eq 0 ] || die "installer parent is writable by another account or group (no driver changes made)"
  listing=$(ls -lde "$1" 2>/dev/null)
  entry=$(printf '%s\n' "$listing" | head -1 | awk '{print $1}')
  [ -n "$entry" ] || die "cannot inspect installer parent access controls"
  # A deny entry only takes access away (some Macs carry "group:everyone deny delete" on /Library); an allow entry can
  # hand another account write access the mode bits above never show, so any allow entry still stops the install and
  # is named in the log.
  case "$entry" in *+*)
    grants=$(printf '%s\n' "$listing" | tail -n +2 | grep -E '^[[:space:]]*[0-9]+:.*[[:space:]]allow[[:space:]]' || true)
    [ -z "$grants" ] || die "installer parent $1 has access-control entries that allow access ($(printf '%s' "$grants" | tr -s ' \n' ' ')) (no driver changes made)"
    ;;
  esac
}

# The installer owns this guard from preflight through commit/rollback. Never
# remove a pre-existing guard: it may belong to an active or interrupted install.
if [ "${CHECK:-0}" != 1 ]; then
  require_install_directory /Library
  if [ ! -e /Library/NullMoth ] && [ ! -L /Library/NullMoth ]; then
    mkdir -m 755 /Library/NullMoth || die "create installer state directory"
  fi
  require_install_directory /Library/NullMoth
  if ! mkdir -m 700 "$LOCKDIR" 2>/dev/null; then
    recover_stale_guard
    mkdir -m 700 "$LOCKDIR" 2>/dev/null || die "installer guard already exists; another install is active right now (no driver changes made)"
  fi
  LOCK_HELD=1
  printf 'pid=%s\nboot=%s\n' "$$" "$(boot_sec)" > "$LOCKDIR/owner" || die "cannot record the installer guard's owner"
  LOCK_ID=$(stat -f '%d:%i' "$LOCKDIR" 2>/dev/null) || die "cannot record installer guard identity"
  printf '%s\n' "$LOCK_ID" | grep -Eq '^[0-9]+:[0-9]+$' || die "installer guard identity is unavailable"
fi

primary_bundle_id() {
 if [ "$1" = NVPrimarySelector ]; then echo org.hackintosh.experimental.NVPrimarySelector
 else echo "com.nullmoth.$1"; fi
}
primary_marker() {
 /usr/libexec/PlistBuddy -c "Print :IOKitPersonalities:$2:IOPropertyMatch:nullmoth-auto-primary" "$1/Contents/Info.plist" 2>/dev/null
}
primary_apply() {
 local bundle=$1 name=$2 plist="$1/Contents/Info.plist" existing
 existing=$(/usr/libexec/PlistBuddy -c "Print :IOKitPersonalities:$name:IOPropertyMatch" "$plist" 2>/dev/null) || existing=''
 if [ -n "$existing" ]; then
  # Do not replace a different PCI/ACPI selection or silently widen its scope.
  [ "$(primary_marker "$bundle" "$name")" = true ] || return 1
  existing=$(/usr/libexec/PlistBuddy -c "Print :IOKitPersonalities:$name:IOPropertyMatch" "$plist") || return 1
  [ "$(printf '%s\n' "$existing" | awk '/ = /{n++}END{print n+0}')" = 1 ] || return 1
 else
  /usr/libexec/PlistBuddy -c "Add :IOKitPersonalities:$name:IOPropertyMatch dict" "$plist" || return 1
  /usr/libexec/PlistBuddy -c "Add :IOKitPersonalities:$name:IOPropertyMatch:nullmoth-auto-primary bool true" "$plist" || return 1
 fi
 codesign --force --sign - "$bundle" && codesign --verify --strict "$bundle"
}
primary_requested() {
 local rm accel
 rm=$(primary_marker "$EXT/NVRM.kext" NVRM) || rm=''
 accel=$(primary_marker "$EXT/NVAccel.kext" NVAccel) || accel=''
 if [ "$rm" = true ] || [ "$accel" = true ]; then
  [ "$rm" = true ] && [ "$accel" = true ] || return 2
  return 0
 fi
 [ "${NM_PRIMARY_GPU:-0}" = 1 ]
}

# An already configured selector is an opt-in that must survive a driver update.
# NM_PRIMARY_GPU=1 is for a first manual installation with a packaged selector.
PRIMARY=0
if [ "$ARCH" = x86_64 ]; then
  primary_requested; primary_status=$?
  case "$primary_status" in
   0) PRIMARY=1;;
   2) die "incomplete primary-GPU matching on installed kexts; no files changed";;
  esac
else
  # the selector makes the card the Mac's display GPU; on Apple Silicon the card drives no display at all
  [ "${NM_PRIMARY_GPU:-0}" != 1 ] || echo "   note: NM_PRIMARY_GPU is ignored on Apple Silicon (the NVIDIA card drives no display there)"
fi
SELECTOR_SOURCE=""
if [ "$PRIMARY" = 1 ]; then
  SELECTOR_SOURCE="$HERE/Library/Extensions/NVPrimarySelector.kext"
  [ -d "$SELECTOR_SOURCE" ] || SELECTOR_SOURCE="$EXT/NVPrimarySelector.kext"
  [ -d "$SELECTOR_SOURCE" ] && [ ! -L "$SELECTOR_SOURCE" ] || die "primary-GPU matching needs NVPrimarySelector.kext; no files changed"
  codesign --verify --strict "$SELECTOR_SOURCE" || die "primary selector signature invalid; no files changed"
  KEXTS="$KEXTS NVPrimarySelector"
fi
# kmutil builds the auxiliary collection from every kext in /Library/Extensions, so one that names a dependency this
# macOS lacks stops the build for all of them. 2.5.3 report: a Realtek USB Wi-Fi kext (RtWlanU1827) needed
# com.apple.iokit.IOUSBFamily, which macOS 15 no longer has, and the stop said only "test kernel collection build
# failed". This names that kext, where it is, and what to do; it is not one of ours, so it is never moved or changed here.
kmutil_blocker() {  # <kmutil log> <extensions folder>: prints a sentence for the user, or nothing
  local log=$1 ext=$2 line id dep path x
  line=$(grep -m1 -oE "Unable to resolve dependencies: '[^']+' names a dependency on '[^']+'" "$log" 2>/dev/null) || return 0
  id=$(printf '%s' "$line" | sed -E "s/^Unable to resolve dependencies: '([^']+)'.*/\1/")
  dep=$(printf '%s' "$line" | sed -E "s/.*names a dependency on '([^']+)'$/\1/")
  case "$id" in com.nullmoth.*|org.hackintosh.experimental.NVPrimarySelector) return 0;; esac
  path=""
  for x in "$ext"/*.kext; do
    [ -f "$x/Contents/Info.plist" ] || continue
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$x/Contents/Info.plist" 2>/dev/null)" = "$id" ] && { path=$x; break; }
  done
  local oc=" (or load it from OpenCore instead)"; [ "${ARCH:-x86_64}" != arm64 ] || oc=""
  printf '%s needs %s, which this macOS does not have, so macOS cannot build a kernel collection while it is there. It is not part of this driver. Move %s out of %s%s, then run 1401 again' \
    "$id" "$dep" "${path:-the kext with that identifier}" "$ext" "$oc"
}
step "3. test kernel collection"
T=$(mktemp -d /var/tmp/nullmoth.XXXX) && [ -n "$T" ] && mkdir -p "$T/repo" || die "create private preflight directory"
for x in "$EXT"/*.kext; do [ -d "$x" ] || continue; n=$(basename "$x" .kext); case " $KEXTS " in *" $n "*) ;; *) cp -R "$x" "$T/repo/" || die "stage third-party kext $n";; esac; done
for k in $KEXTS; do cp -R "$(kpath $k)" "$T/repo/" || die "copy $k"; done
if [ "$PRIMARY" = 1 ]; then
  primary_apply "$T/repo/NVRM.kext" NVRM && primary_apply "$T/repo/NVAccel.kext" NVAccel \
    || die "prepare primary-GPU metadata; no installed files changed"
fi
# macOS 26 kmutil silently skips kexts not owned by root ("No binaries or codeless kexts were provided").
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo" || die "preflight kext permissions"
# On Apple Silicon kmutil create links only with a Kernel Debug Kit for this exact build; without one the test build
# cannot run. That is not the gate there: kernelmanagerd links the kexts into the auxiliary collection after the user
# approves them (step 5), with no KDK, and the kexts' imports were checked against this kernel when they were built.
if [ "$ARCH" = arm64 ] && ! ls -d /Library/Developer/KDKs/*"$BUILD"* >/dev/null 2>&1; then
  echo "   note: no Kernel Debug Kit for build $BUILD, so no test collection is built here; kernelmanagerd links the"
  echo "         kexts after you approve them (step 5). Install the KDK for $BUILD from developer.apple.com to get this preflight."
  ok "preflight done without a test collection"
else
kmutil create -n aux --volume-root / ${KARG[@]+"${KARG[@]}"} -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; why=$(kmutil_blocker "$T/kmutil.log" "$EXT"); hint=$(arm64_kmutil_hint "$T/kmutil.log"); die "test kernel collection build failed${why:+: $why}${hint:+
$hint}"; }
[ -s "$T/aux.kc" ] || die "test kernel collection build produced no output"
INS=$(kmutil inspect -a $KARCH -A "$T/aux.kc" 2>/dev/null) || die "cannot inspect the test kernel collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE '(com\.nullmoth\.[A-Za-z0-9]+|org\.hackintosh\.experimental\.NVPrimarySelector)' | grep -Fxq "$(primary_bundle_id "$k")" || { tail -20 "$T/kmutil.log"; die "kmutil refused com.nullmoth.$k (log above)"; }; done
ok "test collection holds $KEXTS_WORD kexts"
fi
[ "${CHECK:-0}" = 1 ] && { rm -rf "$T"; echo; echo "CHECK PASS (nothing changed)"; exit 0; }

BK=$(mktemp -d "/Library/NullMoth/backup-$(date +%Y%m%d-%H%M%S).XXXXXX") && [ -n "$BK" ] && [ -d "$BK" ] || die "create unique backup directory"
[ "${CHECK:-0}" = 1 ] || printf 'bk=%s\n' "$BK" >> "$LOCKDIR/owner" || die "cannot record the backup in the installer guard"
step "4. back up what is there now -> $BK"
printf '%s\n' "$BUILD" > "$BK/macos-build" || die "record backup macOS build"
[ "$PRIMARY" != 1 ] || touch "$BK/primary-selector-used" || die "record primary selector backup"
# ditto, not cp -Rp: cp re-applies file flags through symlinks and stopped on nvmtl/libvulkan.dylib with "chflags: Too
# many levels of symbolic links" (Mac 1.10 logs 10-10, 2 uploads); ditto keeps links, flags and xattrs, as the restore does.
for k in $KEXTS; do [ ! -e "$EXT/$k.kext" ] || backup_copy "$k" ditto "$EXT/$k.kext" "$BK/$k.kext"; done
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do [ ! -e "$GB/$b" ] || backup_copy "$b" ditto "$GB/$b" "$BK/$b"; done
[ ! -f "$KC" ] || backup_copy "kernel collection" cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc"
[ ! -d /Library/NullMoth/kexts ] || backup_copy "cached accelerators" ditto /Library/NullMoth/kexts "$BK/kexts"
[ ! -f /Library/NullMoth/os-major ] || backup_copy "OS record" cp -p /Library/NullMoth/os-major "$BK/os-major"
[ ! -f /Library/NullMoth/driver-version ] || backup_copy "version record" cp -p /Library/NullMoth/driver-version "$BK/driver-version"
# Back up the firmware from wherever it actually is. This version reads it from $FW, but a release
# before the move kept it in $FWOLD, so on an upgrade $FW does not exist yet and backing up only $FW
# saved nothing. Both restore paths (rollback_install and the boot-guard fallback) are gated on
# $BK/nvfw, so an empty backup made them no-ops: the fallback put the previous driver back with NO
# firmware at all and the Mac came up with no display and no way out. Measured on the test Mac.
if [ -d "$FW" ]; then backup_copy firmware ditto "$FW" "$BK/nvfw"
elif [ -d "$FWOLD" ]; then backup_copy firmware ditto "$FWOLD" "$BK/nvfw"
fi
ok "backup written"

step "5. install"
INSTALLING=1; [ "${CHECK:-0}" = 1 ] || : > "$LOCKDIR/installing"
for k in $KEXTS; do
  source=$(kpath "$k")
  if [ "$PRIMARY" = 1 ]; then source="$T/repo/$k.kext"; fi
  rm -rf "$EXT/$k.kext" && ditto "$source" "$EXT/$k.kext" || die "copy $k (restore from $BK)"
done
if [ "$ARCH" = x86_64 ]; then
# both NVAccel builds stay on disk, so the first start after a macOS upgrade can switch to the matching one
mkdir -p /Library/NullMoth && rm -rf /Library/NullMoth/kexts && ditto "$HERE/Library/NullMoth/kexts" /Library/NullMoth/kexts || die "copy per-macOS accelerators (restore from $BK)"
for target in 15 26; do
  dir=/Library/NullMoth/kexts/$target
  if [ "$PRIMARY" = 1 ]; then
    primary_apply "$dir/NVAccel.kext" NVAccel || die "primary-GPU cache metadata for $target (restore from $BK)"
  fi
  [ -f "$dir/NVAccel.kext/Contents/MacOS/NVAccel" ] && [ -f "$dir/NVAccel.kext/Contents/Info.plist" ] || die "missing macOS $target accelerator (restore from $BK)"
  (cd "$dir" && find NVAccel.kext -type f -exec shasum -a 256 '{}' \;) > "$dir/SHA256SUMS" || die "cache manifest for macOS $target"
done
chown -R root:wheel /Library/NullMoth/kexts && chmod -R go-w /Library/NullMoth/kexts || die "cached accelerator permissions"
fi
echo "$MAJ" > /Library/NullMoth/os-major || die "record selected OS"
mkdir -p "$GB" || die "create the bundle directory"
# The card runs these images and the kernel reads them, so this directory must be ours. It used to live in
# /Users/Shared, which is world-writable (1777): a directory left there by anyone else was adopted as-is,
# because the only permission step was a chmod that adds read bits and never takes write away. Refuse
# anything we did not make, the way the shader caches already refuse a cache someone else could have written.
if [ -e "$FW" ] && [ -n "$(find "$FW" -maxdepth 0 \( ! -user root -o -perm -o+w -o -perm -g+w \) -print -quit 2>/dev/null)" ]; then
  rm -rf "$FW" || die "clear a firmware directory that was not root-owned"
  echo "   note: the firmware folder was writable by other users; it has been replaced"
fi
mkdir -p "$FW" || die "create the firmware directory"
# $GB/nvmtl is replaced wholesale below, so move the shared shader caches aside first. NVMTLLibraryLoad.m
# reads them from NVMTL_AIRCACHE_DIR (/Library/GPUBundles/nvmtl/aircache) and uses that path whenever it is
# writable, which is what lets every process - WindowServer included - share one persistent cache instead of
# compiling into a private one that a reboot or a temp sweep throws away.
CACHEKEPT=""
for c in aircache spvcache; do
  [ ! -d "$GB/nvmtl/$c" ] || { mv "$GB/nvmtl/$c" "$T/keep-$c" && CACHEKEPT="$CACHEKEPT $c" || die "stash $GB/nvmtl/$c"; }
done
# A user's own settings survive updates: the lines between these two markers in nvrm610.conf are put back after the
# copy below. An RTX 3050 (GA106, GH #130) ran only with NVMTL_NO_SURFACE_PAGEOFF=1 and uncached command pools, and every
# update wrote the file fresh and dropped them. Only driver knobs (NVMTL_/NVK_/NVRM_ with plain values) are kept.
MYCONF_START='# --- my settings, kept on update ---'; MYCONF_END='# --- end my settings ---'
[ ! -f "$GB/nvmtl/nvrm610.conf" ] || sed -n "/^$MYCONF_START\$/,/^$MYCONF_END\$/p" "$GB/nvmtl/nvrm610.conf" \
  | grep -E "^($MYCONF_START|$MYCONF_END|(NVMTL|NVK|NVRM)_[A-Z0-9_]+=[A-Za-z0-9._-]{0,64})\$" > "$T/my-conf" || : > "$T/my-conf"
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl; do rm -rf "$GB/$b" && ditto "$HERE/Library/GPUBundles/$b" "$GB/$b" || die "copy $b (restore from $BK)"; done
if [ -s "$T/my-conf" ] && [ -f "$GB/nvmtl/nvrm610.conf" ]; then
  cat "$T/my-conf" >> "$GB/nvmtl/nvrm610.conf" || die "keep your settings in nvrm610.conf (restore from $BK)"
  ok "kept your settings in nvrm610.conf ($(grep -cvE '^#' "$T/my-conf") line(s))"
fi
# nvmtl was just replaced wholesale: when the separate AMD/Intel driver is installed, its Vulkan drivers (which its
# own installer put in /Library/NullMoth/gpu-userland) go back in beside NVK
if [ -d "$EXT/NMXGPU.kext" ] && [ -d /Library/NullMoth/gpu-userland ]; then
  ditto /Library/NullMoth/gpu-userland "$GB/nvmtl" || die "copy the AMD/Intel Vulkan drivers (restore from $BK)"
fi
cp "$HERE/Library/GPUBundles/nvmtl-allow.txt" "$GB/" || die "copy bundle allow list"
ditto "$HERE/Users/Shared/nvfw" "$FW" || die "copy firmware"
chown -R root:wheel "$FW" && chmod -R go-w,a+rX "$FW" || die "firmware permissions"
# nothing reads the old location any more; leaving it behind leaves a writable folder with our name on it
rm -rf "$FWOLD" 2>/dev/null || true
for k in $KEXTS; do chown -R root:wheel "$EXT/$k.kext" && chmod -R 755 "$EXT/$k.kext" || die "permissions for $k"; done
# An update replaces kexts the user already allowed. macOS keeps that approval per bundle (kext_policy; these kexts have
# no team) and the code hash of the copy it last loaded from each path (kext_load_history_v3). For a kext the user
# already allowed at this path, record the new hash, so the record matches what the next start loads. A kext never
# allowed is left to macOS. The database is SIP-protected; the driver's SIP setting (0x0A43) allows root to write it.
# Measured on an update (Core Ultra 5 225F, macOS 26): while this script replaces the loaded kexts macOS shows a
# "kext upgrade" notice, but the first restart loads the new kexts from the collection built below (kernelmanagerd:
# every one "approved", 0 filtered), so an update needs one restart. ALLOWED counts the kexts macOS already allows.
KPDB=/var/db/SystemPolicyConfiguration/KextPolicy; ALLOWED=0
if [ -f "$KPDB" ] && [ -x /usr/bin/sqlite3 ]; then
  for k in $KEXTS; do
    id=$(primary_bundle_id "$k"); p="$EXT/$k.kext"
    printf '%s' "$id" | grep -Eq '^[A-Za-z0-9.]+$' || continue
    [ "$(/usr/bin/sqlite3 "$KPDB" "select allowed from kext_policy where ifnull(team_id,'')='' and bundle_id='$id'" 2>/dev/null)" = 1 ] || continue
    ALLOWED=$((ALLOWED + 1))
    # only NVRM is signed in the package; macOS records the unsigned ones' hashes itself
    ch=$(codesign -dvvv "$p" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
    printf '%s' "$ch" | grep -Eq '^[0-9a-f]{40}$' || continue
    /usr/bin/sqlite3 "$KPDB" "update kext_load_history_v3 set cdhash='$ch' where path='$p' and bundle_id='$id' and ifnull(team_id,'')=''" 2>/dev/null \
      || echo "   note: the approval record for $k is read-only here; macOS may ask to allow it again"
  done
fi
chown -R root:wheel "$GB/NVMTLDriver.bundle" "$GB/NVIDIAShared.bundle" "$GB/nvmtl" "$GB/nvmtl-allow.txt" || die "bundle permissions"
# WindowServer runs as _windowserver and must read the bundles and the allow list. WAS: cp under the app's privileged
# helper (umask 077) left nvmtl-allow.txt at 0600, WindowServer got no Metal device, and CoreDisplay aborted
# ("Failed to create MetalDevice") on every start: the crash loop after install on many machines.
chmod -R go-w,a+rX "$GB/NVMTLDriver.bundle" "$GB/NVIDIAShared.bundle" "$GB/nvmtl" && chmod 644 "$GB/nvmtl-allow.txt" || die "bundle permissions"
sudo -u _windowserver /bin/test -r "$GB/nvmtl-allow.txt" || die "WindowServer cannot read $GB/nvmtl-allow.txt (restore from $BK)"
# Create the shared shader caches the plugin looks for. Without them NVMTL_AIRCACHE_DIR never resolves, so
# WindowServer, which compiles the compositor's pipelines on demand, re-translates them from scratch at every start
# and its content renders black until the translation finishes (community patch #19; ownership below).
# NOTE: this must stay AFTER the "chmod -R go-w ... $GB/nvmtl" above. That recursive chmod would otherwise
# strip the write bits back off aircache/spvcache and the shared cache would silently stop working.
mkdir -p "$GB/nvmtl/aircache" "$GB/nvmtl/spvcache" || die "create the shared shader caches"
# Owned by WindowServer (_windowserver), writable by nobody else: WindowServer loads what is in these caches as
# compiled shaders, so a cache any user can write (1777, as first proposed) would let a local user plant code into
# WindowServer. Other processes see the folders read-only and keep their own private caches, which the plugin already
# does when NVMTL_AIRCACHE_DIR is not writable. A cache kept from an earlier install is reused only if nobody but
# _windowserver could have written into it; otherwise it starts empty.
for c in $CACHEKEPT; do
  [ -d "$T/keep-$c" ] || continue
  if [ -z "$(find "$T/keep-$c" \( ! -user _windowserver -o -perm -o+w -o -perm -g+w \) -print -quit 2>/dev/null)" ]; then
    rm -rf "$GB/nvmtl/$c" && mv "$T/keep-$c" "$GB/nvmtl/$c" || die "restore $GB/nvmtl/$c"
  else rm -rf "$T/keep-$c"; echo "   note: $c was writable by other users; starting it empty"; fi
done
chown -R _windowserver:wheel "$GB/nvmtl/aircache" "$GB/nvmtl/spvcache" || die "shader cache owner"
chmod 0755 "$GB/nvmtl/aircache" "$GB/nvmtl/spvcache" || die "shared shader cache permissions"
if [ "$ARCH" = x86_64 ]; then
NEWKC="$KC.nullmoth-install-new"; rm -f "$NEWKC"
kmutil create -n aux --volume-root / ${KARG[@]+"${KARG[@]}"} -B $KB -S $KS --repository "$EXT" -A "$NEWKC" -z >"$T/kmutil2.log" 2>&1 || die "live kernel collection build failed (restore from $BK)"
[ -s "$NEWKC" ] || die "live kernel collection build produced no output (restore from $BK)"
INS=$(kmutil inspect -a $KARCH -A "$NEWKC" 2>/dev/null) || die "cannot inspect the new kernel collection (restore from $BK)"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE '(com\.nullmoth\.[A-Za-z0-9]+|org\.hackintosh\.experimental\.NVPrimarySelector)' | grep -Fxq "$(primary_bundle_id "$k")" || die "com.nullmoth.$k missing from the new collection (restore from $BK)"; done
mv -f "$NEWKC" "$KC" || die "cannot publish the new kernel collection (restore from $BK)"
else
  arm64_stage_kexts
fi
INSTALLING=0
rm -rf "$T"
ok "installed"
# Record the version for the app's update check. Only the app's setup wrote it, so installs from the release tar left it
# empty and the app kept offering the version already installed (10-10 chat, 1.10.0).
# the licences and notices of everything this package carries, beside the driver they cover
if [ -d "$HERE/licenses" ]; then rm -rf /Library/NullMoth/licenses && ditto "$HERE/licenses" /Library/NullMoth/licenses \
  && chmod -R go-w /Library/NullMoth/licenses || echo "   note: the licence texts could not be copied to /Library/NullMoth/licenses"; fi
if [ -f "$HERE/VERSION" ]; then mkdir -p /Library/NullMoth && tr -cd '0-9.\n' < "$HERE/VERSION" | head -n 1 > /Library/NullMoth/driver-version.tmp \
  && chmod 644 /Library/NullMoth/driver-version.tmp && mv /Library/NullMoth/driver-version.tmp /Library/NullMoth/driver-version; fi

step "6. boot-args"
# A remove flag left by a boot-picker removal that did not finish keeps every NullMoth kext off at boot. Installing
# again means the driver is wanted, so the flag goes; the boot picker sets it again when it is chosen.
nvram -d 7C436110-AB2A-4BBB-A880-FE41995C9F82:nullmoth-remove 2>/dev/null || true

step "6b. falling back to the previous driver if this one cannot start"
# The kernel's boot guard (nvrm_off.h) turns the driver off after two starts in a row that never brought the display
# up, so the Mac reaches a desktop on the firmware's framebuffer. This one-shot job then puts the previous driver back
# from this install's backup and restarts once. It removes itself as soon as the new driver has shown its display
# (nullmoth-nv-ok), so nothing keeps running on a Mac where the update worked. A fresh install has no previous driver to
# go back to: the guard still keeps the Mac usable, and nothing is restored.
nvram -d 7C436110-AB2A-4BBB-A880-FE41995C9F82:nullmoth-nv-starts 2>/dev/null || true
nvram -d 7C436110-AB2A-4BBB-A880-FE41995C9F82:nullmoth-nv-ok 2>/dev/null || true
LG=/Library/NullMoth/lastgood.sh; LGP=/Library/LaunchDaemons/com.nullmoth.lastgood.plist
# On Apple Silicon the restored kexts reach the kernel only through kernelmanagerd's collection rebuild, so the job asks
# for it before it restarts (they were allowed before, so no approval is pending). Empty on x86_64: the job is unchanged.
ARM64_RESTAGE=""
[ "$ARCH" != arm64 ] || ARM64_RESTAGE='for k in '"$KEXTS"'; do [ ! -d "'"$EXT"'/$k.kext" ] || kmutil load -p "'"$EXT"'/$k.kext" >> $LOG 2>&1; done
'
launchctl bootout system/com.nullmoth.lastgood 2>/dev/null || true
rm -f "$LG" "$LGP"
if [ -d "$BK/NVRM.kext" ]; then
  mkdir -p /Library/NullMoth /Library/LaunchDaemons || die "create the fallback job's folders"
  cat > "$LG.tmp" <<EOF || die "write the fallback job"
#!/bin/bash
# Written by the NVIDIA driver install: restores the driver in $BK if the installed one cannot start.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
BK='$BK'; LOG=/Library/NullMoth/lastgood.log; V=7C436110-AB2A-4BBB-A880-FE41995C9F82
# no launchctl bootout here: booting out the running job kills this script before it can restart the Mac (10-17 test)
done_job() { rm -f /Library/LaunchDaemons/com.nullmoth.lastgood.plist /Library/NullMoth/lastgood.sh; }
if nvram \$V:nullmoth-nv-ok >/dev/null 2>&1; then echo "\$(date) the new driver brought its display up; keeping it" >> \$LOG; done_job; exit 0; fi
v=\$(nvram \$V:nullmoth-nv-starts 2>/dev/null | cut -f2)
case "\$v" in %0[2-9a-f]|%[1-9a-f]?) ;; *) exit 0;; esac
[ -d "\$BK/NVRM.kext" ] || { echo "\$(date) the driver turned itself off but its backup \$BK is gone" >> \$LOG; done_job; exit 0; }
echo "\$(date) the new driver did not bring the display up twice; restoring the previous driver from \$BK" >> \$LOG
for k in $KEXTS; do rm -rf "$EXT/\$k.kext"; [ ! -e "\$BK/\$k.kext" ] || ditto "\$BK/\$k.kext" "$EXT/\$k.kext"; done
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do rm -rf "$GB/\$b"; [ ! -e "\$BK/\$b" ] || ditto "\$BK/\$b" "$GB/\$b"; done
rm -rf /Library/NullMoth/kexts "$FW"
[ ! -d "\$BK/kexts" ] || ditto "\$BK/kexts" /Library/NullMoth/kexts
[ ! -d "\$BK/nvfw" ] || ditto "\$BK/nvfw" "$FW"
# the previous driver may be one that reads the old location
[ ! -d "\$BK/nvfw" ] || { mkdir -p "$FWOLD" && ditto "\$BK/nvfw" "$FWOLD"; }
if [ -f "\$BK/AuxiliaryKernelExtensions.kc" ]; then cp -p "\$BK/AuxiliaryKernelExtensions.kc" "$KC"; else rm -f "$KC"; fi
[ ! -f "\$BK/os-major" ] || cp -p "\$BK/os-major" /Library/NullMoth/os-major
if [ -f "\$BK/driver-version" ]; then cp -p "\$BK/driver-version" /Library/NullMoth/driver-version; else rm -f /Library/NullMoth/driver-version; fi
${ARM64_RESTAGE}nvram -d \$V:nullmoth-nv-starts 2>/dev/null
echo "previous" > /Library/NullMoth/driver-restored
done_job
echo "\$(date) previous driver restored; restarting" >> \$LOG
shutdown -r now
EOF
  chmod 755 "$LG.tmp" && chown root:wheel "$LG.tmp" && mv -f "$LG.tmp" "$LG" || die "install the fallback job"
  cat > "$LGP" <<EOF || die "write the fallback job's plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.nullmoth.lastgood</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$LG</string></array>
<key>RunAtLoad</key><true/></dict></plist>
EOF
  chmod 644 "$LGP" && chown root:wheel "$LGP" || die "fallback job permissions"
  ok "previous driver kept as the fallback ($BK)"
else
  ok "no previous driver to fall back to (first install)"
fi
step "6c. counting a start as good once the desktop is up"
# The kernel's guard only counts a start as good when the framebuffer lights a head, or when the card reports that none
# of its connectors has a display. A laptop whose panel hangs off the integrated GPU reaches that report late and does
# not always reach it: two boots that missed it switched a healthy driver off, leaving the Mac with no NVIDIA card in
# Metal at all. A desktop that comes up and stays up is also a good start, so this job says so. A boot that never
# reaches a desktop keeps its count, which is what the guard is for.
BG=/Library/NullMoth/bootguard.sh; BGP=/Library/LaunchDaemons/com.nullmoth.bootguard.plist
launchctl bootout system/com.nullmoth.bootguard 2>/dev/null || true
mkdir -p /Library/NullMoth /Library/LaunchDaemons || die "create the boot-guard job's folders"
if [ "$ARCH" = x86_64 ]; then
cat > "$BG.tmp" <<'EOF' || die "write the boot-guard job"
#!/bin/bash
# Written by the NVIDIA driver install: the desktop came up, so this start counts as good.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=7C436110-AB2A-4BBB-A880-FE41995C9F82; LOG=/Library/NullMoth/bootguard.log
n=0
while [ "$n" -lt 48 ]; do
  if pgrep -x WindowServer >/dev/null 2>&1; then
    sleep 45
    pgrep -x WindowServer >/dev/null 2>&1 || { n=$((n + 1)); continue; }
    nvram -d $V:nullmoth-nv-starts 2>/dev/null
    nvram $V:nullmoth-nv-ok=1 2>/dev/null
    echo "$(date) the desktop came up and stayed up; this start counts as good" >> $LOG
    exit 0
  fi
  n=$((n + 1)); sleep 5
done
echo "$(date) no desktop within four minutes; the start keeps its count" >> $LOG
EOF
else
# Apple Silicon: the desktop is on Apple's GPU, so "the desktop came up" says nothing about this driver, and no NVRMFB
# clears the kernel's counter (nvrm_off.h) when a head lights: without this job two ordinary starts would switch a
# working driver off. A start counts as good once NVRM.kext is loaded and GSP-RM is running on the card, which NVRM
# reports by publishing nvrm-gpu-profile on the card's PCI device (NVRM.cpp, publishGpuProfile, after PASS 2). A card
# that is not plugged in never starts NVRM and is never counted either way.
cat > "$BG.tmp" <<'EOF' || die "write the boot-guard job"
#!/bin/bash
# Written by the NVIDIA driver install (Apple Silicon): NVRM is loaded and the card is up, so this start counts as good.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=7C436110-AB2A-4BBB-A880-FE41995C9F82; LOG=/Library/NullMoth/bootguard.log
n=0
while [ "$n" -lt 48 ]; do
  if kmutil showloaded --list-only --bundle-identifier com.nullmoth.NVRM 2>/dev/null | grep -q com.nullmoth.NVRM \
     && ioreg -r -c IOPCIDevice -d 1 2>/dev/null | grep -q '"nvrm-gpu-profile"'; then
    nvram -d $V:nullmoth-nv-starts 2>/dev/null
    # NVRAM writes can be refused under some boot policies; the kernel's own counter then keeps what it has
    nvram $V:nullmoth-nv-ok=1 2>/dev/null || echo "$(date) NVRAM could not be written; the start is good but not recorded" >> $LOG
    echo "$(date) NVRM is loaded and the card is up; this start counts as good" >> $LOG
    exit 0
  fi
  n=$((n + 1)); sleep 5
done
echo "$(date) NVRM did not bring the card up within four minutes; the start keeps its count" >> $LOG
EOF
fi
chmod 755 "$BG.tmp" && chown root:wheel "$BG.tmp" && mv -f "$BG.tmp" "$BG" || die "install the boot-guard job"
cat > "$BGP" <<EOF || die "write the boot-guard job's plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.nullmoth.bootguard</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$BG</string></array>
<key>RunAtLoad</key><true/></dict></plist>
EOF
chmod 644 "$BGP" && chown root:wheel "$BGP" || die "boot-guard job permissions"
if [ "$ARCH" = x86_64 ]; then ok "a start counts as good once the desktop is up"
else ok "a start counts as good once NVRM has brought the card up"; fi

ba=$(nvram boot-args 2>/dev/null | cut -f2-)
if [ "$ARCH" = x86_64 ]; then
for a in nvfb=1 nvaccel=1; do case " $ba " in *" $a "*) ;; *) echo "   NOTE: boot-args lack '$a' — add it in your OpenCore config.plist (README: Install — by hand), or let the 1401 Mac app set OpenCore up";; esac; done
# WhateverGreen's boot screen copy (on unless gfxrst=4) reads a console mapping macOS may already have freed when this
# driver's display first opens, and the Mac panics in IOFramebuffer::postOpen.
if kmutil showloaded --list-only --bundle-identifier as.vit9696.WhateverGreen 2>/dev/null | grep -q WhateverGreen; then
  case " $ba " in *" gfxrst=4 "*) ;; *) echo "   NOTE: WhateverGreen is loaded and boot-args lack 'gfxrst=4' — add it in your OpenCore config.plist, or the Mac can panic when the NVIDIA display first opens";; esac
fi
else
# What the Apple Silicon kexts read (grep PE_parse_boot_argn kexts/NVRM kexts/NVAccelArm): nothing is needed to start
# NVRM, and NVAccelArm reads only nvaccelfake=1 (its bring-up recording mode). nvfb=1 belongs to NVRMFB and nvaccel=1 to
# the x86 NVAccel, neither of which exists here. The AMFI arguments are what let WindowServer and every app load the
# unsigned Metal plugin bundle, as on Intel. OpenCore and WhateverGreen do not exist on this Mac: boot-args live in NVRAM,
# which macOS may write only under Permissive Security; otherwise they are set from recoveryOS Terminal.
miss=""
for a in amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0; do case " $ba " in *" $a "*) ;; *) miss="$miss $a";; esac; done
if [ -n "$miss" ]; then
  echo "   NOTE: boot-args lack$miss — without them WindowServer and apps cannot load the Metal plugin (the kexts still load)."
  echo "         Set them from macOS under Permissive Security, or from recoveryOS Terminal (power button held at start > Options > Utilities > Terminal):"
  echo "           sudo nvram boot-args=\"$(echo $ba$miss)\""
fi
echo "   Optional boot-args read by these kexts: -nvoff (keeps the driver off), nvaccelfake=1 (NVAccelArm answers Metal's probes),"
echo "   -nvrmnogo, -nvrmnopm, nvrmsettle=<ms>, nvrmholdcap=<s>, nvrmdiag=1, nvrmmapowner=0, -nvrmsmallbar, nvmaxbpc=<n>."
fi

echo; echo "Done. Reboot now: sudo shutdown -r now"
if [ "$ARCH" = arm64 ] && [ "$ARM64_APPROVE" = 1 ]; then
  echo "macOS is waiting for you: open System Settings > Privacy & Security, allow the NullMoth extensions (the notice may say"
  echo "\"System Extension Blocked\"), and restart when macOS asks. The restart after the approval builds the kernel collection,"
  echo "so the driver is up from the start after that one."
elif [ "$ALLOWED" = "$(echo $KEXTS | wc -w | tr -d ' ')" ]; then
  echo "This is an update of extensions you already allowed: one restart is enough. macOS may show a notice that they were"
  echo "updated; the new driver loads on this restart without allowing them again."
else
  echo "If macOS asks, allow the extensions in System Settings > Privacy & Security, then reboot once more."
fi
echo "Undo: sudo ./uninstall.sh $BK"
