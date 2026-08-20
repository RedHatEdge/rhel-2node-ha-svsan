#!/bin/bash
# Stages the amd64 Neutral Storage Host binaries from a StorMagic package you
# have already downloaded, so they can be built into a container image.
#
#   ./extract-nsh.sh ~/Downloads/svsan_6-7_plugin_ova.zip
#
# Nothing belonging to StorMagic is committed to this repository — you supply the
# package, and the binaries stay in your build context.
#
# Why this package: the appliance it contains carries the amd64 SvSAN toolset
# under /opt/stormagic/SvSAN, including the witness daemons together with their
# own loader and glibc, which is what makes them straightforward to containerise.
#
# StorMagic also document a witness RPM. If you have one, or your support contact
# can provide a packaged amd64 witness, use that in preference to this script --
# a vendor-supplied package is always the better starting point.
set -euo pipefail

ZIP="${1:-}"
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "usage: $0 <svsan_*_plugin_ova.zip>"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
# The image is 16 GB uncompressed. Never do this under /tmp on a systemd host:
# /tmp is tmpfs, so it is RAM, and this will evict everything else.
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking $ZIP"
unzip -oq "$ZIP" '*.ova' -d "$WORK"
OVA="$(find "$WORK" -name '*.ova' -print -quit)"
tar xf "$OVA" -C "$WORK" --wildcards '*.vmdk'
VMDK="$(find "$WORK" -name '*.vmdk' -print -quit)"

echo "==> converting appliance disk (this takes a minute)"
qemu-img convert -O raw "$VMDK" "$WORK/plugin.raw"
rm -f "$VMDK"

# GPT: p1 is a 1 MB BIOS boot partition, p2 is the root filesystem at 2 MiB.
echo "==> carving root filesystem"
dd if="$WORK/plugin.raw" of="$WORK/root.img" bs=1M skip=2 status=none
rm -f "$WORK/plugin.raw"

echo "==> extracting NSH daemons and runtime"
mkdir -p "$HERE/bin" "$HERE/lib"
for f in smclusterd smdiscod smc_state smdisco exlog; do
    debugfs -R "dump /opt/stormagic/SvSAN/bin/$f $HERE/bin/$f" "$WORK/root.img" 2>/dev/null
done
for f in $(debugfs -R "ls /opt/stormagic/SvSAN/lib" "$WORK/root.img" 2>/dev/null \
             | tr -s ' \n' '\n' | grep -E '^(ld-|lib)'); do
    debugfs -R "dump /opt/stormagic/SvSAN/lib/$f $HERE/lib/$f" "$WORK/root.img" 2>/dev/null
done
debugfs -R "dump /opt/stormagic/SvSAN/dirs $HERE/dirs" "$WORK/root.img" 2>/dev/null
chmod +x "$HERE"/bin/* "$HERE"/lib/ld-linux-x86-64.so.2

file -b "$HERE/bin/smclusterd" | grep -q 'x86-64' \
    || { echo "ERROR: extracted binary is not x86-64"; exit 1; }

echo "==> done"
ls -la "$HERE/bin"
echo
echo "build with:  podman build -t nsh-witness $HERE"
