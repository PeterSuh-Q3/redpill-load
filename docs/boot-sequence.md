# 부팅 시퀀스 및 모듈 로딩 타이밍 / Boot Sequence & Module Loading Timing

---

## 한국어

### 개요

redpill-load 기반 DSM 부팅 과정에서 커널 모듈이 어떤 순서로, 어느 시점에 로드되는지 정리합니다.
특히 BMI2 비지원 CPU(Ivy Bridge 3세대, Goldmont Plus J4125 등)에서 소프트웨어 에뮬레이터 모듈(`bmi2_emul.ko`)을 
올바른 시점에 삽입하기 위한 구조 이해가 목적입니다.

---

### 전체 부팅 플로우

```
┌─────────────────────────────────────────────────────────┐
│ 1. GRUB (synoboot1 파티션, 72MB FAT ESP)                 │
│    ├─ zImage 로드     → Synology kpatched DSM 커널       │
│    └─ rd.gz 로드      → 로더 ramdisk (loader initramfs)  │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│ 2. 커널 초기화 (kernel/init/main.c)                       │
│    ├─ start_kernel()                                     │
│    │    └─ trap_init()  → #UD / #GP 등 예외 핸들러 설정  │
│    └─ load_default_elevator_module()                     │
│         └─ /sbin/modprobe elevator-iosched 호출 (UMH)   │
│              ★ 이 시점이 최초 유저스페이스 코드 실행점   │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│ 3. iosched-trampoline5.sh  (/sbin/modprobe 심링크)       │
│    ├─ insmod /usr/lib/modules/bmi2_emul.ko  ← (★ 삽입점)│
│    │    → #UD 핸들러 등록 완료                           │
│    ├─ insmod /usr/lib/modules/rp.ko                      │
│    │    → RedPill shim 등록 (stealth, usb_boot_shim 등) │
│    ├─ rm /sbin/modprobe                                  │
│    ├─ ln -s /bin/busybox /sbin/modprobe                  │
│    └─ modprobe $@  (원래 요청된 모듈 계속 처리)          │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│ 4. DSM 로더 ramdisk init 스크립트                         │
│    └─ /exts/ 안의 익스텐션 모듈 순차 로드               │
│         ├─ usbcore, xhci_hcd, xhci_pci                  │
│         ├─ e1000e / vmxnet3 (NIC 드라이버)               │
│         ├─ ata_piix, mptscsih, mptbase (스토리지)        │
│         └─ 기타 서드파티 모듈                            │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│ 5. kexec → 실제 DSM 런타임 커널로 전환                    │
│    └─ /.syno/patch/zImage (DSM 운영 커널)                │
└─────────────────────────────────────────────────────────┘
```

---

### 파티션 구조

| 파티션 | 크기 | 내용 |
|--------|------|------|
| synoboot1 (p1) | 72MB FAT ESP | GRUB + zImage + rd.gz (로더 커널 + ramdisk) |
| synoboot2 (p2) | — | GRUB 설정, GRUB_VER 등 |
| synoboot3 (p3) | — | rd.gz (DSM 원본 ramdisk), zImage (DSM 운영 커널) |

- **synoboot1/zImage** = 로더가 사용하는 커널. 기본은 Synology kpatched 커널이며,  
  `all-modules` 익스텐션이 활성화된 경우 `ext/official-zImage/` 의 커스텀 커널로 교체됨.
- **synoboot3/zImage** = kexec 대상인 실제 DSM 운영 커널.

---

### ramdisk 내 /exts 구조

빌드 시 `build-loader_t.sh`가 `ext-manager.sh _dump_exts`를 호출하여  
`custom.gz` ramdisk 레이어 안의 `/exts/` 디렉토리에 익스텐션 모듈을 배치합니다.

```
custom.gz (ramdisk layer)
└─ exts/
   └─ all-modules/
       └─ epyc7002-7.3-5.10.55/
           ├─ vmxnet3.ko
           ├─ e1000e.ko
           └─ ...
```

---

### BMI2 에뮬레이터 삽입 전략

#### 문제

Synology DSM 커널은 `-march=haswell` 로 컴파일되어 BMI2 명령어  
(MULX, PDEP, PEXT, BZHI, SARX, SHRX, SHLX, RORX)를 포함합니다.  
Ivy Bridge / J4125 CPU는 BMI2를 지원하지 않아 `#UD` (Illegal Instruction) 예외가 발생합니다.

#### 해결 방향

`bmi2_emul.ko` 모듈은 `register_die_notifier()`로 `#UD` 핸들러를 설치하고,  
3-byte VEX 인코딩된 BMI2 명령어를 소프트웨어로 에뮬레이션합니다.

#### 삽입 위치: iosched-trampoline5.sh (단계 3)

```sh
# /usr/sbin/modprobe (= iosched-trampoline5.sh)
insmod /usr/lib/modules/bmi2_emul.ko   # ← 추가: 최초 유저스페이스에서 #UD 핸들러 등록
insmod /usr/lib/modules/rp.ko
rm /sbin/modprobe
ln -s /bin/busybox /sbin/modprobe
modprobe $@
```

이 시점이 실질적으로 가장 이른 삽입 지점입니다.  
`rp.ko` 로드 전, 그리고 NIC/스토리지 드라이버 로드 전에 에뮬레이터가 활성화됩니다.

#### 한계

커널 `start_kernel()` ~ `trap_init()` 구간(단계 2)은 어떤 모듈도 로드되기 전입니다.  
만약 Synology 커널의 **기본 초기화 코드**에 BMI2 명령어가 포함되어 있다면,  
이 구간에서 `#UD` 발생 → 에뮬레이터가 아직 로드되지 않아 커널 패닉이 발생합니다.  
이 경우 kpatch 수준의 바이너리 패치가 추가로 필요합니다.

---

### 관련 파일

| 파일 | 역할 |
|------|------|
| `build-loader_t.sh` | 전체 로더 이미지 빌드 스크립트 |
| `config/_common/iosched-trampoline5.sh` | `/sbin/modprobe` 트램폴린 (최초 모듈 로딩 진입점) |
| `ext/official-zImage/bzImage-*.gz` | BMI2-free 커스텀 커널 (GPL 빌드, `-march=ivybridge`) |
| `src/bmi2_emul/bmi2_emul.c` | BMI2 소프트웨어 에뮬레이터 소스 |
| `src/bmi2_emul/bmi2_emul.ko` | Synology 커널 ABI 기준으로 빌드된 에뮬레이터 모듈 |
| `src/build4.sh` | GPL 소스 기반 ivybridge 커널 빌드 스크립트 |

---
---

## English

### Overview

This document describes the order and timing of kernel module loading during the redpill-load based DSM boot process.
The primary goal is to understand the boot structure for correctly inserting the software emulator module
(`bmi2_emul.ko`) at the earliest possible point — required for CPUs without BMI2 support
(Ivy Bridge 3rd Gen, Goldmont Plus J4125, etc.).

---

### Full Boot Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. GRUB  (synoboot1 partition, 72MB FAT ESP)                 │
│    ├─ Load zImage  → Synology kpatched DSM kernel            │
│    └─ Load rd.gz   → Loader ramdisk (loader initramfs)       │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 2. Kernel Initialization  (kernel/init/main.c)               │
│    ├─ start_kernel()                                         │
│    │    └─ trap_init()  → installs #UD / #GP exception handlers│
│    └─ load_default_elevator_module()                         │
│         └─ calls /sbin/modprobe elevator-iosched  (UMH)     │
│              ★ First userspace code executed                 │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 3. iosched-trampoline5.sh  (symlinked as /sbin/modprobe)     │
│    ├─ insmod /usr/lib/modules/bmi2_emul.ko  ← (★ insert here)│
│    │    → #UD die_notifier registered                        │
│    ├─ insmod /usr/lib/modules/rp.ko                          │
│    │    → RedPill shims registered (stealth, usb_boot etc.) │
│    ├─ rm /sbin/modprobe                                      │
│    ├─ ln -s /bin/busybox /sbin/modprobe                      │
│    └─ modprobe $@  (handle originally requested module)      │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 4. DSM Loader Ramdisk init scripts                           │
│    └─ Sequential modprobe of extension modules in /exts/    │
│         ├─ usbcore, xhci_hcd, xhci_pci                      │
│         ├─ e1000e / vmxnet3  (NIC drivers)                   │
│         ├─ ata_piix, mptscsih, mptbase  (storage drivers)   │
│         └─ other third-party modules                        │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 5. kexec → switch to DSM runtime kernel                      │
│    └─ /.syno/patch/zImage  (DSM operating kernel)           │
└─────────────────────────────────────────────────────────────┘
```

---

### Partition Layout

| Partition | Size | Contents |
|-----------|------|----------|
| synoboot1 (p1) | 72MB FAT ESP | GRUB + zImage + rd.gz (loader kernel + ramdisk) |
| synoboot2 (p2) | — | GRUB config, GRUB_VER, etc. |
| synoboot3 (p3) | — | rd.gz (original DSM ramdisk), zImage (DSM runtime kernel) |

- **synoboot1/zImage** = Kernel used by the loader. Defaults to the Synology kpatched kernel.  
  When `all-modules` extension is active, replaced with the custom kernel from `ext/official-zImage/`.
- **synoboot3/zImage** = The actual DSM operating kernel that is the kexec target.

---

### /exts Directory Structure in Ramdisk

During build, `build-loader_t.sh` calls `ext-manager.sh _dump_exts` to place extension  
modules into the `/exts/` directory inside the `custom.gz` ramdisk layer.

```
custom.gz  (ramdisk layer)
└─ exts/
   └─ all-modules/
       └─ epyc7002-7.3-5.10.55/
           ├─ vmxnet3.ko
           ├─ e1000e.ko
           └─ ...
```

---

### BMI2 Emulator Insertion Strategy

#### Problem

The Synology DSM kernel is compiled with `-march=haswell`, which emits BMI2 instructions
(MULX, PDEP, PEXT, BZHI, SARX, SHRX, SHLX, RORX).
CPUs without BMI2 support (Ivy Bridge, J4125) will raise `#UD` (Undefined Instruction) exceptions,
causing an immediate kernel panic.

#### Solution

`bmi2_emul.ko` installs a `#UD` handler via `register_die_notifier()` and emulates
3-byte VEX-encoded BMI2 instructions entirely in software.

#### Insertion Point: iosched-trampoline5.sh (Stage 3)

```sh
# /usr/sbin/modprobe  (= iosched-trampoline5.sh)
insmod /usr/lib/modules/bmi2_emul.ko   # ← Added: register #UD handler at first userspace entry
insmod /usr/lib/modules/rp.ko
rm /sbin/modprobe
ln -s /bin/busybox /sbin/modprobe
modprobe $@
```

This is the earliest practical insertion point.  
The emulator becomes active before `rp.ko`, before any NIC/storage driver is loaded.

#### Limitation

The window from `start_kernel()` to `trap_init()` (Stage 2) runs before any module can be loaded.
If the Synology kernel's **early initialization code** contains BMI2 instructions,
a `#UD` will occur before the emulator is installed, resulting in a kernel panic.
In that case, a binary patch at the kpatch level targeting `do_invalid_op` would be required.

---

### Related Files

| File | Purpose |
|------|---------|
| `build-loader_t.sh` | Main loader image build script |
| `config/_common/iosched-trampoline5.sh` | `/sbin/modprobe` trampoline (first module load entry point) |
| `ext/official-zImage/bzImage-*.gz` | BMI2-free custom kernel (GPL build, `-march=ivybridge`) |
| `src/bmi2_emul/bmi2_emul.c` | BMI2 software emulator source |
| `src/bmi2_emul/bmi2_emul.ko` | Emulator module built against Synology kernel ABI |
| `src/build4.sh` | GPL-source ivybridge kernel build script |
