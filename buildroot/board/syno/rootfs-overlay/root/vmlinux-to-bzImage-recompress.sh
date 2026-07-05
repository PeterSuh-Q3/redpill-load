#!/usr/bin/env bash
# Repack a kpatch'd vmlinux back into the ORIGINAL zImage by re-LZMA-compressing
# the payload and reusing the genuine setup+decompressor.
#
# Rationale: the fixed-template method (vmlinux-to-bzImage.sh) embeds the vmlinux
# UNCOMPRESSED into a small template whose decompressor is sized for ~34MB kernels.
# Oversized kernels (e.g. epyc7003ntb / PAS7700, 37MB vmlinux) either overflow the
# template or cannot be relocated by that decompressor -> triple fault at kexec.
#
# This method keeps the genuine bzImage container (setup + decompressor + init_size)
# and only swaps the compressed payload, so the genuine decompressor boots it just
# like the stock kernel.
#
# Usage: vmlinux-to-bzImage-recompress.sh <vmlinux-mod> <orig-zImage> <out-zImage>
#
# Payload layout in the genuine bzImage:
#   [lzma_alone stream (payload_length-4 bytes)] [4-byte LE uncompressed size]
# We recompress vmlinux-mod as lzma_alone (props 0x5d, 64MiB dict, EOS-terminated
# via -9e). Because the new stream is <= the original stream, we zero-pad it back to
# the exact original length. Every offset (payload_length, appended size, tail, and
# the decompressor's baked z_input_len) stays byte-identical to the genuine image.

set -e

VMLINUX_MOD="${1}"
ORIG_ZIMAGE="${2}"
OUT="${3}"
LOG_FILE="/tmp/log"

# --- locate an LZMA-compression-capable xz --------------------------------------
# BusyBox xz/lzma can only DEcompress, so probe for a real xz (tinycore xz.tcz
# installs one at /usr/local/bin/xz). Load the extension on demand if needed.
XZ=""
for cand in /usr/local/bin/xz xz; do
  if echo -n "" | "${cand}" --format=lzma -9e -c >/dev/null 2>&1; then XZ="${cand}"; break; fi
done
if [ -z "${XZ}" ]; then
  command -v tce-load >/dev/null 2>&1 && tce-load -wil xz >/dev/null 2>&1 || true
  echo -n "" | /usr/local/bin/xz --format=lzma -9e -c >/dev/null 2>&1 && XZ="/usr/local/bin/xz"
fi
if [ -z "${XZ}" ]; then
  echo "[recompress] no LZMA-compression-capable xz found (busybox xz cannot compress)" >&2
  exit 1
fi

read_u8()  { dd if="${1}" bs=1 skip=$(($2)) count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }
read_u32() { dd if="${1}" bs=1 skip=$(($2)) count=4 2>/dev/null | od -An -tu4 | tr -d ' '; }

setup_sects=$(read_u8  "${ORIG_ZIMAGE}" 0x1f1)
payload_offset=$(read_u32 "${ORIG_ZIMAGE}" 0x248)
payload_length=$(read_u32 "${ORIG_ZIMAGE}" 0x24c)
pstart=$(( (setup_sects + 1) * 512 + payload_offset ))
stream_len=$(( payload_length - 4 ))

# 1) recompress (lzma_alone matching kernel format: props 0x5d, 64MiB dict, EOS)
"${XZ}" --format=lzma -9e -c "${VMLINUX_MOD}" > /tmp/stream.new 2>>"${LOG_FILE}"
new_len=$(stat -c%s /tmp/stream.new)

if [ "${new_len}" -gt "${stream_len}" ]; then
  echo "[recompress] new lzma stream ${new_len} > original ${stream_len} - cannot pad-fit" >&2
  rm -f /tmp/stream.new
  exit 1
fi

pad=$(( stream_len - new_len ))

# 2) reassemble: genuine head + new stream + zero-pad + genuine (appended size + tail)
head -c "${pstart}" "${ORIG_ZIMAGE}" > "${OUT}"
cat /tmp/stream.new >> "${OUT}"
[ "${pad}" -gt 0 ] && head -c "${pad}" /dev/zero >> "${OUT}"
tail -c +$(( pstart + stream_len + 1 )) "${ORIG_ZIMAGE}" >> "${OUT}"

rm -f /tmp/stream.new
