#!/bin/bash
# Large-capacity variant of vmlinux-to-bzImage.sh for oversized kernels (e.g. epyc7003ntb, 37MB+ vmlinux).
# Uses bzImage-template-v5-large.gz (payload capacity 40MB, init_size 48MB).
# Offsets: payload@14561, size fields @41957601 & @41973312.
LOG_FILE="/tmp/log"
crc32() { gzip -c "$1" | tail -c8 | od -t x4 -N 4 -A n; }
file_size_le() {
  printf $(
    dec_size=0
    for F in "${@}"; do dec_size=$((dec_size + $(stat -c "%s" "${F}"))); done
    printf "%08x\n" ${dec_size} | sed 's/\(..\)/\1 /g' | {
      read ch0 ch1 ch2 ch3
      for ch in ${ch3} ${ch2} ${ch1} ${ch0}; do printf '%s%03o' '\' $((0x${ch})); done
    }
  )
}
size_le() {
  printf $(
    printf "%08x\n" "${@}" | sed 's/\(..\)/\1 /g' | {
      read ch0 ch1 ch2 ch3
      for ch in ${ch3} ${ch2} ${ch1} ${ch0}; do printf '%s%03o' '\' $((0x${ch})); done
    }
  )
}
SCRIPT_DIR=$(dirname "$0")
VMLINUX_MOD="${1}"
ZIMAGE_MOD="${2}"
gzip -dc "${SCRIPT_DIR}/bzImage-template-v5-large.gz" > "${ZIMAGE_MOD}" || exit 1
dd if="${VMLINUX_MOD}" of="${ZIMAGE_MOD}" bs=14561    seek=1 conv=notrunc >"${LOG_FILE}" 2>&1 || exit 1
file_size_le "${VMLINUX_MOD}" | dd of="${ZIMAGE_MOD}" bs=41957601 seek=1 conv=notrunc >"${LOG_FILE}" 2>&1 || exit 1
file_size_le "${VMLINUX_MOD}" | dd of="${ZIMAGE_MOD}" bs=41973312 seek=1 conv=notrunc >"${LOG_FILE}" 2>&1 || exit 1
size_le $(($((16#$(crc32 "${ZIMAGE_MOD}" | awk '{print$1}'))) ^ 0xFFFFFFFF)) | dd of="${ZIMAGE_MOD}" conv=notrunc oflag=append >"${LOG_FILE}" 2>&1 || exit 1
