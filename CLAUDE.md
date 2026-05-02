# Global Preferences
- 한국어로 응답
- 코드 설명은 간결하게, 핵심만
- 커널 오류 분석 순서: RIP → Call Trace → 원인

---

# Redpill LKM — 작업 컨텍스트

## 한 줄 요약
DSM을 비 Synology 하드웨어에서 실행하기 위한 LKM.
mfgBIOS 인터셉트, 하드웨어 센서 에뮬레이션, SCSI/SATA 포트 타입 교정.

## 빠른 빌드
```bash
make dev-v7 LINUX_SRC=<path> PLATFORM=apollolake   # 디버그
make prod-v7 LINUX_SRC=<path> PLATFORM=apollolake  # 릴리즈
```

## 현재 작업 상태 (매 세션 업데이트)

### ✅ 완료된 과제 (2026-04-29 ~ 04-30)
- bromolow RS18016xs+ DSM 설치 시 BIOS Update -21 에러 해결
- LKM 4단 방어로 H2OFFT 검증 체인 우회 (kernel <= 3.10.108 가드)
  - `bios_access_fixer` (access("bios.ROM") → ENOENT)
  - `block_module_load_shim` (isfl_drv/lfdd_drv 차단)
  - `install_backup_shim` (rollback 백업 prefill)
  - `bios_hwcap_shim` (id=8 강제 support=1)

### ✅ 완료된 과제 (2026-05-01)
**SATA(AHCI) 디스크 DSM 디스크 관리자 미표시 문제 해결**

- **증상**: Junior 모드에서는 SATA 디스크 정상 인식 → DSM 설치 성공.
  로그인 후 DSM 디스크 관리자에는 해당 디스크가 표시되지 않음.
- **진단 결과** (Dev LKM + dmesg + /var/log/messages 분석):
  - `synoinfo.conf`: `supportsas="yes"` (RS18016xs+는 본질적으로 SAS HBA 모델)
  - DSM의 `synodiskd`/`synodiskfind`가 `/sys/class/sas_host/*` glob 검색
  - VMware AHCI 환경에는 `sas_host`가 존재하지 않음
  - 결과: `SYNOEnclosureListEnum()` 실패 → `DiskInfoEnum()` 실패 → 디스크 미표시
- **해결**: `synoinfo.conf`의 `supportsas="no"`로 패치 → 디스크 정상 인식 확인
- **사이드 이펙트 매트릭스**:
  | 환경 | `supportsas="no"` 영향 |
  |---|---|
  | VMware/Hyper-V/Proxmox AHCI | ✅ 무영향 |
  | 물리 SATA 직접 | ✅ 무영향 |
  | LSI HBA IT-mode + SATA HDD | 🟡 LKM `sata_port_shim`이 처리 (대부분 정상) |
  | LSI HBA + 진짜 SAS HDD | ⚠️ SAS 전용 기능 (Multipath 등) 손실 |
  | SAS expander / sas-EUNIT (rx1217sas 등) | ❌ 인식 불가 |
- **권장 추가 작업** (선택): ramdisk 패치에 SAS HBA 자동 감지 분기 추가
  → SAS HBA 있으면 `supportsas="yes"` 유지, 없으면 `"no"` 적용

### 핵심 발견 — Non-DT 플랫폼의 sata_port_shim 동작

- bromolow + AHCI 환경에서 `sata_port_shim`은 정상 동작하나 효과가 거의 없음
  - AHCI 드라이버가 이미 `hostt->syno_port_type = SYNO_PORT_TYPE_SATA`로 설정
  - `is_fixable()` → false (수정 불필요)
  - LKM은 silent skip
- bromolow에서 `/sys/block/sdX/device/syno_port_type` sysfs는 본래 부재
  (broadwellnk와 동일 — DSM은 `synodiskd`가 다른 경로로 분류)
- 따라서 **본 문제의 진짜 원인은 LKM 측이 아닌 DSM 측 모델 정의**(`supportsas="yes"`)에 있었음

### kernel cmdline (검증된 값)
```
SataPortMap=8 DiskIdxMap=00
synoboot_satadom=2
syno_hw_version=RS18016xs+
```

### 다음 과제 후보
- (옵션) ramdisk 패치에 SAS HBA 자동 감지 분기 추가
- (옵션) bromolow 외 다른 플랫폼에서도 동일 문제 검증
- (옵션) DS3615xs 등 SATA-only 모델로 변경 시 단순화 가능 여부


## 비코드 핵심 지식 (코드에 없는 것만)
- `scsi_notifier_list.c`만 `-std=gnu89` (GCC bug #275674)
- 시리얼 로그: /dev/ttyUSB0 @ 115200, 타임스탬프 [sec.usec] 형식

## 자주 참조하는 파일
- 초기화 순서: @redpill_main.c
- 심볼 패치 메커니즘: @internal/override/override_symbol.c
- 플랫폼 설정: @config/platforms.h

# Bromolow BIOS Update 에러 분석 — Claude Code 인수인계

> **작성 기준**: 2026-04-29 세션 분석  
> **대상 플랫폼**: bromolow (Linux 3.10.x)  
> **증상**: DSM 설치 중 BIOS Update 단계에서 에러코드 `-21` 발생  
> **관련 파일**: `shim/block_fw_update_shim.c`, `internal/intercept_execve.c`

---

## 현재 BIOS Update 차단 메커니즘

### 등록 흐름

```
redpill_main.c :: init_()
  └─ register_execve_interceptor()        # SyS_execve 심볼 훅
  └─ register_fw_update_shim()
       ├─ add_blocked_execve_filename("./H2OFFT-Lx64")
       ├─ add_blocked_execve_filename("./H2OFFT-Lx64-0815")
       └─ patch_dmi()                     # DMI_PRODUCT_NAME → "Synoden"
```

### 차단 동작 (Linux < 4.19, bromolow 3.10 해당)

```c
// internal/intercept_execve.c
if (unlikely(strcmp(pathname, intercepted_filenames[i]) == 0)) {
    pr_loc_inf("Blocked %s from running", pathname);
    do_exit(0);   // 프로세스 종료, 부모에게 exit code 0 전달
}
```

### 플랫폼 설정 (bromolow)

```c
// config/platforms.h
#elif defined(RP_PLATFORM_BROMOLOW)
const struct hw_config platformConfig = {
    .name = "",   // "DS3615xs" — 빈 문자열 주의
    .emulate_rtc = false,
    .swap_serial = false,
    .reinit_ttyS0 = true,
    ...
};
```

> `hw_config`에 `block_fw_update` 플래그 없음 — 모든 플랫폼에서 무조건 등록됨.

---

## 원인 가설 (가능성 순)

### 🔴 가설 A — 펌웨어 업데이터 경로 불일치 (가장 유력)

**근거**

- 차단 로직은 `strcmp()` 정확 일치만 수행
- 차단 등록된 경로: `./H2OFFT-Lx64`, `./H2OFFT-Lx64-0815`
- RS18016xs+ 인스톨러가 절대경로(`/tmp/H2OFFT-Lx64`) 또는 다른 바이너리명 사용 가능

**확인 방법**

```bash
# 1. RPDBG_EXECVE 플래그 활성화 후 빌드
#    Makefile 또는 CMakeLists.txt에서 -DRPDBG_EXECVE 추가

# 2. dmesg에서 실제 호출 경로 확인
dmesg | grep -E "execve|Blocked|H2OFFT"

RackStation> dmesg | grep -E "execve|Blocked|H2OFFT"
[   10.251628] <redpill/intercept_execve.c:108> Registering execve() interceptor
[   10.252618] <redpill/override_symbol.c:256> Overriding SyS_execve() with SyS_execve_shim [redpill]()<ffffffffa0000830>
[   10.253730] <redpill/override_symbol.c:171> Saved SyS_execve() ptr <ffffffff8112f1c0>
[   10.256759] <redpill/override_symbol.c:206> Obtaining lock for <SyS_execve+0x0/0x50/ffffffff8112f1c0>
[   10.258575] <redpill/override_symbol.c:186> Generated trampoline to SyS_execve_shim+0x0/0x10 [redpill]<ffffffffa0000830> for SyS_execve<ffffffff8112f1c0>: 
[   10.262761] <redpill/override_symbol.c:268> Successfully overrode SyS_execve() with trampoline to SyS_execve_shim+0x0/0x10 [redpill]<ffffffffa0000830>
[   10.263634] <redpill/intercept_execve.c:122> execve() interceptor registered
[   10.279642] <redpill/intercept_execve.c:61> Filename uboot_do_upd.sh will be blocked from execution
[   10.280765] <redpill/intercept_execve.c:61> Filename ./uboot_do_upd.sh will be blocked from execution
[   10.281640] <redpill/intercept_execve.c:61> Filename /usr/syno/bin/syno_pstore_collect will be blocked from execution
[   10.283637] <redpill/intercept_execve.c:61> Filename /tmpData/upd@te/sas_fw_upgrade_tool will be blocked from execution
[   10.284654] <redpill/intercept_execve.c:61> Filename /usr/syno/sbin/syno_oob_fw_upgrade will be blocked from execution
[   10.287656] <redpill/intercept_execve.c:61> Filename ./H2OFFT-Lx64 will be blocked from execution
[   10.288651] <redpill/intercept_execve.c:61> Filename ./H2OFFT-Lx64-0815 will be blocked from execution
[   10.417273] <redpill/call_protected.c:88> Got addr ffffffff8112ef90 for do_execve
[   35.621291] <redpill/intercept_execve.c:87> Blocked /usr/syno/bin/syno_pstore_collect from running

# 3. 설치 패키지 내 바이너리 경로 직접 확인
find /tmp -name "H2OFFT*" 2>/dev/null
-> 결과 없음
find / -name "H2OFFT*" 2>/dev/null
-> 결과 없음
```

**수정 검토**

```c
// 현재 (정확 일치)
if (unlikely(strcmp(pathname, intercepted_filenames[i]) == 0))

// 개선안 1 — basename 매칭 (경로 무관하게 차단)
const char *base = strrchr(pathname, '/');
base = base ? base + 1 : pathname;
if (unlikely(strcmp(base, "H2OFFT-Lx64") == 0 ||
             strcmp(base, "H2OFFT-Lx64-0815") == 0))

// 개선안 2 — strstr 포함 매칭 (더 넓게)
if (unlikely(strstr(pathname, "H2OFFT") != NULL))
```

> **주의**: strstr 방식은 의도치 않은 바이너리까지 차단할 수 있으므로 basename 매칭 권장.

---

### 🔴 가설 B — DMI_PRODUCT_NAME 패치 조용한 실패

**근거**

```c
// shim/block_fw_update_shim.c :: patch_dmi()
char *ptr = (char *)dmi_get_system_info(DMI_PRODUCT_NAME);
if (unlikely(ptr == 0)) {
    pr_loc_err("Error getting DMI_PRODUCT_NAME, impossible to patch DMI");
    return;   // ← 에러 리턴 없이 그냥 복귀
}
```

- `register_fw_update_shim()`은 `patch_dmi()` 실패와 무관하게 `0`(성공) 반환
- LKM은 정상 로드되지만 DMI 패치 미적용 → H2OFFT가 보드명 검증 실패 → 에러 반환

**확인 방법**

```bash
# DMI 현재 값 확인
cat /sys/class/dmi/id/product_name
Synoden

# dmesg에서 패치 실패 로그 확인
dmesg | grep "DMI_PRODUCT_NAME"
-> 결과 없음
```

**수정 검토**

```c
// patch_dmi()를 int 반환으로 변경하고 register_fw_update_shim()에서 체크
static int patch_dmi(void) {
    char *ptr = (char *)dmi_get_system_info(DMI_PRODUCT_NAME);
    if (unlikely(ptr == NULL)) {
        pr_loc_err("Error getting DMI_PRODUCT_NAME");
        return -ENODATA;
    }
    ...
    return 0;
}

int register_fw_update_shim(void) {
    ...
    out = patch_dmi();
    if (out != 0)
        return out;   // 실패 시 상위로 전파
    ...
}
```

---

### 🟡 가설 C — DMI 검증 필드 불일치

**근거**

- 현재 코드: `DMI_PRODUCT_NAME`만 패치
- RS18016xs+ 버전의 H2OFFT가 `DMI_BOARD_NAME` 또는 다른 필드로 보드 검증 가능

**확인 방법**

```bash
# 모든 DMI 필드 출력
cat /sys/class/dmi/id/*
dmidecode 2>/dev/null | grep -A2 "System Information"
```

**수정 검토**: H2OFFT 바이너리를 `strings` 또는 분석 도구로 검사해 참조 DMI 필드 확인.

---

### 🟢 가설 D — SyS_execve 심볼 부재 (낮음)

**근거**: Linux 3.10에서 execve는 어셈블리 스텁으로 구현 가능 → `SyS_execve` 심볼 없을 수 있음.  
다만 이 경우 LKM 로드 자체가 실패해야 하므로 가능성 낮음.

**확인 방법**

```bash
grep SyS_execve /proc/kallsyms
ffffffff8112f1c0 T SyS_execve
ffffffffa0000830 t SyS_execve_shim      [redpill]

grep -E "execve" /proc/kallsyms
ffffffff8112e8e0 t do_execve_common.isra.0
ffffffff8112ef90 T do_execve
ffffffff8112f1c0 T SyS_execve
ffffffff8112f1c0 T sys_execve
ffffffff8112f210 T compat_sys_execve
ffffffff814c0200 T stub_execve
ffffffff814c2580 T stub32_execve
ffffffffa00007a0 t SYSC_execve_shim     [redpill]
ffffffffa0005326 t SYSC_execve_shim.cold        [redpill]
ffffffffa0000830 t SyS_execve_shim      [redpill]
ffffffffa0005351 t add_blocked_execve_filename.cold     [redpill]
ffffffffa0005751 t _do_execve.cold      [redpill]
ffffffffa0000930 t _do_execve   [redpill]
ffffffffa0000840 t add_blocked_execve_filename  [redpill]
ffffffffa000547b t register_execve_interceptor  [redpill]
ffffffffa000557e t unregister_execve_interceptor        [redpill]
```

---

## 디버깅 순서

```
1. [ ] RPDBG_EXECVE 빌드 → dmesg에서 실제 H2OFFT 경로 확인
2. [ ] dmesg에서 "Error getting DMI_PRODUCT_NAME" 유무 확인
3. [ ] /sys/class/dmi/id/product_name 값 확인 (패치 적용 여부)
4. [ ] find / -name "H2OFFT*" → 실제 경로 파악
5. [ ] grep SyS_execve /proc/kallsyms → 심볼 존재 확인
6. [ ] 원인 특정 후 수정 적용 및 재테스트
```

**시리얼 로그 캡처**

```bash
screen /dev/ttyUSB0 115200
# 또는
minicom -D /dev/ttyUSB0 -b 115200
```

---

## 참조 파일

| 파일 | 역할 |
|---|---|
| `redpill_main.c` | 초기화 순서, shim 등록 체인 |
| `shim/block_fw_update_shim.c` | H2OFFT 차단 + DMI 패치 |
| `internal/intercept_execve.c` | execve 훅, 경로 비교 로직 |
| `shim/bios_shim.c` | synobios vtable 인터셉트 |
| `shim/bios/bios_shims_collection.c` | vtable 개별 함수 shim |
| `config/platforms.h` | bromolow 플랫폼 설정 (`RP_PLATFORM_BROMOLOW`) |
| `internal/override/override_symbol.c` | 심볼 패치 메커니즘 |

---

## 빌드 참고

```bash
# bromolow 디버그 빌드
make dev-v7 LINUX_SRC=../linux-3.10.x-bromolow-25426 PLATFORM=bromolow

# RPDBG_EXECVE 추가 시
make dev-v7 LINUX_SRC=../linux-3.10.x-bromolow-25426 PLATFORM=bromolow \
     EXTRA_CFLAGS="-DRPDBG_EXECVE"
```

> `scsi_notifier_list.c`는 반드시 `-std=gnu89` 적용 (GCC bug #275674)


+ ---
+
+ # Coding Principles (Anthropic Standard)
+

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
