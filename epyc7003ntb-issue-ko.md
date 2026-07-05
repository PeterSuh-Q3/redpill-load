# epyc7003ntb (PAS7700/FS3420): 패치된 zImage가 kexec에서 트리플 폴트 — 미압축 템플릿이 아니라 payload 재압축 방식이 필요함

## 요약

**epyc7003ntb** (PAS7700 / FS3420, DSM **7.4.0-101188**, 커널 5.10.55)에서 패치된 `zImage`가 `kexec` 시점에 즉시 트리플 폴트를 일으킵니다 (VMware "virtual CPU entered shutdown state" 다이얼로그, 또는 실기에서 즉시 재부팅 루프). cmdline에 `earlycon=uart8250,io,0x3f8,115200n8`이 있어도 **시리얼 출력이 전혀 없습니다.**

근본 원인: 이 커널의 `vmlinux`가 고정 템플릿 재포장 방식으로 담기에 너무 큽니다. 해결책은 정품 `setup`+decompressor를 그대로 재사용하고 LZMA payload만 교체하는 것입니다.

## 환경

| | |
|---|---|
| 플랫폼 | epyc7003ntb (PAS7700, FS3420) |
| DSM | 7.4.0-101188 |
| 커널 | 5.10.55 (GCC 12.2.0) |
| 테스트 CPU | Intel i7-10700 (VMware), Ryzen 3300X, 실기 — 모두 동일하게 실패 |

## 재현 절차

1. epyc7003ntb / PAS7700 (DSM 7.4.0-101188)용 로더를 빌드합니다.
2. 부팅 → DSM 커널이 kexec에서 트리플 폴트. 시리얼 출력이 전혀 없음 (`earlycon`이 있어도).

## 근본 원인

- 압축 해제된 `vmlinux` = **37,288,424 B (37.3 MB)**; 정품 `zImage` = 6.5 MB (LZMA payload 6,491,207 B), `init_size` = **44,195,840**.
- 템플릿 재포장(`vmlinux-to-bzImage.sh`)은 vmlinux를 **미압축** 상태로 `bzImage-template-v5`에 삽입하는데, 이 템플릿은:
  - payload 용량이 **34,448,860 B**밖에 안 되고 (payload@`14561`, size 필드@`34463421`),
  - decompressor head가 ~34 MB 커널 기준으로 빌드되어 있습니다 (`init_size` 34,918,400).
- 37.3 MB 커널은 템플릿을 **초과**합니다. 심지어 용량을 키운 **대용량 템플릿**(40 MB 용량, `init_size` 48 MB, 오프셋 재계산, payload 라운드트립 바이트 일치 검증 완료)을 만들어도 **여전히 무출력 트리플 폴트**가 납니다 — 템플릿의 decompressor head가 37 MB 이미지를 relocate하지 못하기 때문입니다. 크래시는 **earlycon 초기화보다 앞선** 시점, 즉 decompressor / kexec 핸드오프 단계에서 발생합니다.

## 원인 격리 (배제한 것들)

1. **kpatch는 정상** — epyc7003ntb에서 정확히 **5바이트**만 변경 (`OR→AND` ×4 + ramdisk check), SA6400와 동일. 원인 아님.
2. **정품 `zImage`는 완전히 부팅됨** — 수정하지 않은 PAS7700 `zImage`를 kexec하면 `[0.000000] Linux version …`부터 출력하며 790초 가동까지 도달하고, `Loading of unsigned module is rejected`(kpatch 미적용 시 당연한 결과)에서만 멈춥니다. → **커널 / kexec / 환경은 정상.**
3. 모든 재포장 방식(템플릿, 대용량 템플릿, 그리고 우리 테스트의 `rebuild-bzimage`)이 **earlycon 前**에 실패 → 결함은 커널이 아니라 재포장의 decompressor 단계에 있음.

## 해결책: 정품 컨테이너 재사용, payload만 교체

```
정품 zImage = [ setup + decompressor | LZMA payload | tail ]
                        유지                교체        유지
```

1. 정품 payload를 풀어 → `vmlinux`; kpatch → `vmlinux-mod` (크기 불변, 37,288,424 B).
2. `vmlinux-mod`를 커널 포맷과 동일한 **lzma_alone**으로 재압축: `xz --format=lzma -9e` → props `0x5d`, 64 MiB dict, EOS 종료. 결과 **6,479,672 B ≤** 원본 스트림(6,491,203 B).
3. 새 스트림을 원본 스트림 길이로 **제로패딩**; 정품의 4바이트 부착 크기와 tail은 그대로 유지.

모든 오프셋(`payload_length`@0x24c, 부착 크기, tail, decompressor에 박힌 `z_input_len`)이 **바이트 단위로 동일**하게 유지되고 payload 내용만 바뀝니다. 정품 decompressor + `init_size`(44.2 MB)는 이 커널에 맞게 이미 올바르므로(정품 부팅이 증명), 수정 없이 그대로 부팅됩니다.

**검증 완료:** `bzImage-to-vmlinux.sh`로 다시 추출 시 `vmlinux-mod`와 바이트 단위로 일치하며, **실기에서 DSM 부팅 성공**.

---

## 로그 발췌

### ① 정품(미수정) `zImage` — 완전히 부팅, earlycon이 `[0.000000]`부터 동작

```text
[    0.000000] Linux version 5.10.55+ (root@build4) (x86_64-pc-linux-gnu-gcc (GCC) 12.2.0, GNU ld (GNU Binutils) 2.38) #101188 SMP Thu May 7 23:11:13 CST 2026
[    0.000000] Command line: dsm withefi earlyprintk console=ttyS0,115200n8 ... earlycon=uart8250,io,0x3f8,115200n8 ... syno_hw_version=PAS7700 panic=0 mev=vmware
[    0.000000] KERNEL supported cpus:
[    0.000000]   Intel GenuineIntel
[    0.000000]   AMD AuthenticAMD
[    0.000000]   Hygon HygonGenuine
...
[  790.503928] ...        <- 790초 가동까지 도달, 트리플 폴트/패닉 없음
```

### ② 동일한 정품 부팅 — 유일한 실패는 unsigned-module 거부 (kpatch 미적용이라 당연)

```text
[   16.107429] Loading of unsigned module is rejected
[   16.107429] Loading of unsigned module is rejected
```

> 이것이 정확히 *패치되지 않은* 커널의 동작입니다 — 정품 decompressor와 커널은 건강하며, 모듈 서명 우회(kpatch의 `OR→AND` 패치)만 빠진 상태입니다. kpatch를 적용하면 해결됩니다.

### ③ 패치된 `zImage` (템플릿 / 대용량 템플릿 재포장) — 실패

```text
(시리얼 출력이 전혀 없음 — 위의 [0.000000] 줄조차 안 나옴)
=> VMware: "A fault has occurred causing a virtual CPU to enter the shutdown state"
   (트리플 폴트, earlycon 초기화 前)
```

> **출력이 전혀 없다는 것**이 핵심 신호입니다: 동일한 cmdline(같은 `earlycon=uart8250,io,0x3f8`)에서 정품 커널은 `[0.000000]`부터 출력하는데, 템플릿 재포장 커널은 **아무것도** 출력하지 않습니다 → 메인 커널이 실행되기 前, decompressor / kexec 핸드오프에서 죽는 것입니다.

### 비교 표

| 커널 이미지 | 시리얼 출력 | 결과 |
|---|---|---|
| 정품 `zImage` (미수정) | `[0.000000]` → 790초 | 부팅됨; "unsigned module rejected"만 발생 |
| 템플릿 재포장 (미압축, 34 MB 용량) | **없음** | 트리플 폴트 (잘림 / decompressor 불일치) |
| 대용량 템플릿 (미압축, 40 MB 용량) | **없음** | 트리플 폴트 (decompressor가 37 MB relocate 불가) |
| **payload 재압축** (정품 decompressor + 재-LZMA payload) | `[0.000000]` → 완전 부팅 | **DSM 부팅 성공** ✅ |

---

## 근거 데이터

### ④ kpatch는 SA6400(정상)와 PAS7700(실패)에서 동일하게 동작 — kpatch 배제

```text
--- SA6400 (epyc7002, 부팅됨) ---          --- PAS7700 (epyc7003ntb) ---
kpatch exit = 0                            kpatch exit = 0
Found .init.text @ 1E1B000                 Found .init.text @ 225A000
Found .rodata    @ 81C00000 / E00000       Found .rodata    @ 81E00000 / 1000000
Patching boot params.                      Patching boot params.
Patching OR to AND @ 1E4967B               Patching OR to AND @ 2289681
Patching OR to AND @ 1E496D1               Patching OR to AND @ 22896D7
Patching OR to AND @ 1E4970B               Patching OR to AND @ 2289711
Patching OR to AND @ 1E4971E               Patching OR to AND @ 2289724
Patching ramdisk check.                    Patching ramdisk check.
Patching call to rtc_cmos_write.           Patching call to rtc_cmos_write.
변경된 바이트 수: 5                         변경된 바이트 수: 5
vmlinux 크기: 불변 (32,803,304)            vmlinux 크기: 불변 (37,288,424)
```

> 동일한 패치 세트, 동일한 5바이트 변경, 동일한 성공 — 커널별 오프셋만 다릅니다. kpatch는 문제가 아닙니다.

### ⑤ bzImage 헤더 비교 — 템플릿의 `init_size`가 이 커널에 비해 너무 작음

| 필드 (오프셋) | 정품 PAS7700 `zImage` | `bzImage-template-v5` | SA6400 (들어맞음) |
|---|---|---|---|
| 압축 해제 `vmlinux` | **37,288,424** | — | 32,803,304 |
| `payload_length` (0x24c) | 6,491,207 (LZMA) | 34,448,864 (미압축) | — |
| **`init_size` (0x260)** | **44,195,840** | **34,918,400** | — |
| 템플릿 payload 용량 | — | 34,448,860 | — |

> 템플릿의 decompressor는 `init_size` 34.9 MB, ~34 MB payload 창으로 빌드되어 있습니다. PAS7700 커널은 **`init_size` 44.2 MB**와 37.3 MB 이미지가 필요해 들어맞지 않으며, 용량만 키운 템플릿도 작은 decompressor의 가정을 그대로 유지합니다.

### ⑥ 재포장 라운드트립 검증 (payload 재압축 방식)

```text
$ vmlinux-to-bzImage-recompress.sh vmlinux-mod  genuine-zImage  out.zImage
   xz --format=lzma -9e  ->  스트림 6,479,672 B  (<= 원본 6,491,203, 헤더 5d 00 00 00 04 ff..ff)
   6,491,203로 제로패딩 + 4바이트 크기  ->  payload 6,491,207 (동일)
   out.zImage = 6,523,248 B   payload_length=6,491,207   init_size=44,195,840   (전부 정품과 바이트 동일)

$ bzImage-to-vmlinux.sh out.zImage  vmlinux.roundtrip
   vmlinux.roundtrip == vmlinux-mod   ->  일치  (kpatch의 5바이트 보존됨)
```

> 재-LZMA된 payload는 원본보다 작으므로 제로패딩으로 정확한 스트림 길이를 복원합니다. 모든 구조적 오프셋이 동일하게 유지되고 payload 내용만 바뀝니다. 라운드트립과 실기 DSM 부팅 모두 확인됨.

---

## `rebuild-bzimage`에 대한 참고

정품 커널이 부팅되므로 올바른 전체 재빌드도 원칙적으로는 동작해야 하지만, 우리 테스트에서 `rebuild-bzimage` 경로는 epyc7003ntb에서 여전히 트리플 폴트가 났습니다. 37 MB / `init_size` 44 MB 커널을 올바르게 처리하는지 확인이 필요합니다 (예: `z_output_len` / relocation 버퍼 크기). 위의 payload 교체 방식은 정품 decompressor를 그대로 재사용하는, 오프셋을 보존하는 최소한의 대안입니다.

## 환경 주의사항

재압축에는 **진짜 xz**가 필요합니다 — BusyBox `xz`/`lzma`는 해제 전용입니다. TinyCore에서는 `xz.tcz`(xz 5.2.5)가 로드되어 있는지 확인하거나 정적 xz를 번들해야 합니다.
