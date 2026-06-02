#!/bin/bash
LOG=/work/build4.log
exec > >(tee $LOG) 2>&1
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq flex bison cpio libelf-dev rsync kmod xxd python3

export PATH="/opt/epyc7002/bin:$PATH"
export ARCH=x86_64
export CROSS_COMPILE=x86_64-pc-linux-gnu-
export KCFLAGS="-march=ivybridge"
export HOSTCFLAGS="-Wno-deprecated-declarations -Wno-error"

rm -rf /tmp/build
cp -r /work/linux-src /tmp/build
cd /tmp/build

echo "+" > localversion

# hydrogen stub
rm -f include/crypto/hydrogen.h
cp /work/hydrogen-stub.h include/crypto/hydrogen.h
DUMMY_KEY=$(python3 -c "print(', '.join(['0x00']*32))")
sed -i "s/__RAMDISK_SIGN_PUBLIC_KEY__/${DUMMY_KEY}/" init/initramfs.c
DEC=$(shuf -i 1001-2147483647 -n 1)
sed -i "s/__DECOMPRESSION_TYPE__/${DEC}/" arch/x86/boot/compressed/head_64.S 2>/dev/null || true
sed -i "s/__DECOMPRESSION_TYPE__/${DEC}/" lib/synolib/syno_kexec_test.c 2>/dev/null || true

# tools/ -Werror 제거 (objtool OpenSSL 3.0 경고 억제 — STACK_VALIDATION은 유지)
find tools -type f \( -name "Makefile*" -o -name "*.mk" -o -name "Build" \) 2>/dev/null \
  | xargs -r sed -i 's/-Werror[[:space:]]/-Wno-error /g; s/-Werror$/-Wno-error/g' 2>/dev/null

cp synology/synoconfigs/epyc7002 .config
scripts/config --disable MODULE_SIG_ALL --disable MODULE_SIG_FORCE --disable MODULE_SIG
scripts/config --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS
scripts/config --disable DEBUG_INFO_BTF
scripts/config --disable SYNO_RAMDISK_INTEGRITY_CHECK
# ★ STACK_VALIDATION / UNWINDER_ORC 는 원본 synoconfig 그대로 유지 (비활성화 안 함)

make olddefconfig 2>&1 | tail -3

echo ""
echo "=== 핵심 설정 확인 ==="
grep -E "^CONFIG_(STACK_VALIDATION|UNWINDER_ORC|UNWINDER_FRAME|DEBUG_ATOMIC_SLEEP|ERROR_INJECTION)" .config

echo ""
echo "=== vmlinux 빌드 ==="
date
make -j$(nproc) HOSTCFLAGS="-Wno-deprecated-declarations -Wno-error" vmlinux > /work/build4-vmlinux.log 2>&1
VM_RC=$?
echo "vmlinux exit: $VM_RC"
if [ $VM_RC -ne 0 ]; then
  tail -50 /work/build4-vmlinux.log
  grep -nE "Error|error:|fatal" /work/build4-vmlinux.log | head -20
  exit 1
fi

echo ""
echo "=== bzImage 빌드 ==="
make -j$(nproc) HOSTCFLAGS="-Wno-deprecated-declarations -Wno-error" bzImage > /work/build4-bzImage.log 2>&1
BZ_RC=$?
echo "bzImage exit: $BZ_RC"
[ $BZ_RC -ne 0 ] && { tail -30 /work/build4-bzImage.log; exit 1; }

echo ""
echo "=== 검증 ==="
date
ls -la vmlinux arch/x86/boot/bzImage System.map
ls -la Module.symvers 2>/dev/null || echo "(Module.symvers not found — skipping)"
strings vmlinux | grep "Linux version 5\.10" | head -1
python3 -c "
import re
for p,n in [('vmlinux','vmlinux'),('arch/x86/boot/bzImage','bzImage')]:
    d=open(p,'rb').read()
    bmi2=(len(re.findall(rb'\xc4\xe2.\xf5',d))+len(re.findall(rb'\xc4\xe2.\xf6',d))
         +len(re.findall(rb'\xc4\xe2.\xf7',d))+len(re.findall(rb'\xc4\xe3.\xf0',d)))
    print(f'{n}: size={len(d):,}, BMI2={bmi2}')
"

echo ""
echo "=== __might_sleep export 여부 확인 ==="
/opt/epyc7002/bin/x86_64-pc-linux-gnu-nm vmlinux 2>/dev/null | grep -E " [TtRrDd] (__might_sleep|__might_fault|___might_sleep)" | head -5

cp vmlinux /work/vmlinux-ivybridge-v2
cp arch/x86/boot/bzImage /work/bzImage-ivybridge-v2
[ -f Module.symvers ] && cp Module.symvers /work/Module.symvers-ivybridge-v2 || echo "(Module.symvers not found — skip copy)"
cp System.map /work/System.map-ivybridge-v2
ls -la /work/*-ivybridge-v2
