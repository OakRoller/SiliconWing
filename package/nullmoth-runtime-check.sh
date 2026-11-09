#!/bin/bash
# nullmoth-runtime-check.sh <package root> <macOS version>: can the user-space runtime in this package load on this Mac?
# Run by install.sh before anything is copied. Exit 0 = yes. Checks that every Mach-O the Metal plugin, the translator
# and NVK need is present, carries a slice for this machine (and x86_64 for Rosetta on Apple Silicon), and that each
# links only against libraries that exist here. It loads nothing into the kernel and changes nothing.
set -u
P=${1:?package root}; V=${2:-?}
arch=$(uname -m); fail=0
say() { printf '   %s\n' "$*"; }
need() { [ -e "$1" ] || { say "missing: ${1#"$P"/}"; fail=1; return 1; }; }
GB="$P/Library/GPUBundles"
need "$GB/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" || exit 1
need "$GB/NVMTLDriver.bundle/Contents/Info.plist"
need "$GB/nvmtl/libvulkan_nouveau.dylib" || exit 1
need "$GB/nvmtl-allow.txt"
for f in "$GB/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" "$GB/NVMTLDriver.bundle/Contents/MacOS/libnvmtl_translate.dylib" "$GB/nvmtl/libvulkan_nouveau.dylib"; do
  [ -e "$f" ] || continue
  archs=$(lipo -archs "$f" 2>/dev/null) || { say "not a Mach-O: ${f#"$P"/}"; fail=1; continue; }
  case " $archs " in *" $arch "*) ;; *) say "${f#"$P"/} has no $arch slice ($archs)"; fail=1;; esac
  if [ "$arch" = arm64 ]; then case " $archs " in *" x86_64 "*) ;; *) say "note: ${f#"$P"/} has no x86_64 slice: apps under Rosetta get no NVIDIA device";; esac; fi
  # every dependent library must exist (on disk or in the shared cache; dyld's cache keeps system libraries off disk,
  # so a /System or /usr/lib path is accepted by name)
  id=$(otool -D "$f" 2>/dev/null | sed -n 2p)   # a dylib's own install name is listed first and is not a dependency
  while IFS= read -r dep; do
    [ "$dep" = "$id" ] && continue
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*) ;;
      /System/*|/usr/lib/*) ;;
      *) [ -e "$dep" ] || { say "${f#"$P"/} links $dep, which this Mac does not have"; fail=1; };;
    esac
  done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
done
# the plugin's bitcode reader: Apple's GPUCompiler libLLVM (shared cache) unless the package bundles air-runtime
if [ ! -e "$GB/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib" ] && [ ! -d /System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023 ]; then
  say "no bundled air-runtime and no GPUCompiler 32023 on this macOS $V: shader libraries could not be read"; fail=1
fi
[ "$fail" = 0 ] && say "ok  runtime slices and dependencies present for $arch (macOS $V)"
exit $fail
