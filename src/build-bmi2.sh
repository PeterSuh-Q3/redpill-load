#!/bin/bash
# build-bmi2.sh — Build bmi2_emul.ko against Synology epyc7002 kernel headers
#
# Must be run inside or via dante90/syno-compiler:7.3 Docker image.
# Output: /work/bmi2_emul.ko (Synology kernel ABI compatible)

set -e
LOG=/work/build-bmi2.log
exec > >(tee "$LOG") 2>&1

echo "=== bmi2_emul build start ==="
date

# Verify KSRC is usable
KSRC=/opt/epyc7002/build
if [ ! -f "${KSRC}/Makefile" ]; then
    echo "ERROR: ${KSRC}/Makefile not found"
    exit 1
fi
echo "KSRC = ${KSRC}"
echo "Kernel version: $(cat ${KSRC}/include/config/kernel.release 2>/dev/null || echo unknown)"

export PATH="/opt/epyc7002/bin:$PATH"
export ARCH=x86_64
export CROSS_COMPILE=x86_64-pc-linux-gnu-

# Build
cp -r /work/bmi2_emul_src /tmp/bmi2_build
cd /tmp/bmi2_build

make KSRC="${KSRC}" 2>&1

echo ""
echo "=== Build result ==="
ls -lh bmi2_emul.ko
file bmi2_emul.ko
/opt/epyc7002/bin/x86_64-pc-linux-gnu-nm bmi2_emul.ko | grep -E "bmi2|emul|register_die"

cp bmi2_emul.ko /work/bmi2_emul.ko
echo ""
echo "=== bmi2_emul.ko written to /work/bmi2_emul.ko ==="
date
