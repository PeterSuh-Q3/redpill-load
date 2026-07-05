# epyc7003ntb (PAS7700/FS3420): patched zImage triple-faults at kexec — needs payload-recompress repack, not the uncompressed template

## Summary

On **epyc7003ntb** (PAS7700 / FS3420, DSM **7.4.0-101188**, kernel 5.10.55), the patched `zImage` triple-faults immediately at `kexec` (VMware "virtual CPU entered shutdown state", or an instant reboot loop on bare metal), with **zero serial output** even when `earlycon=uart8250,io,0x3f8,115200n8` is on the cmdline.

Root cause: this kernel's `vmlinux` is too large for the fixed-template repack. The fix is to reuse the genuine `setup`+decompressor and swap only the LZMA payload.

## Environment

| | |
|---|---|
| Platform | epyc7003ntb (PAS7700, FS3420) |
| DSM | 7.4.0-101188 |
| Kernel | 5.10.55 (GCC 12.2.0) |
| Tested CPUs | Intel i7-10700 (VMware), Ryzen 3300X, real hw — all fail identically |

## Reproduction

1. Build a loader for epyc7003ntb / PAS7700 (DSM 7.4.0-101188).
2. Boot → DSM kernel triple-faults at kexec. No serial output at all (even with `earlycon`).

## Root cause

- Decompressed `vmlinux` = **37,288,424 B (37.3 MB)**; genuine `zImage` = 6.5 MB (LZMA payload 6,491,207 B), `init_size` = **44,195,840**.
- The template repack (`vmlinux-to-bzImage.sh`) embeds the vmlinux **uncompressed** into `bzImage-template-v5`, whose:
  - payload capacity is only **34,448,860 B** (payload@`14561`, size field@`34463421`), and
  - decompressor head is built for a ~34 MB kernel (`init_size` 34,918,400).
- The 37.3 MB kernel **overflows** the template. Even a purpose-built **larger** template (40 MB capacity, `init_size` 48 MB, offsets recomputed, payload round-trip byte-perfect) **still triple-faults with no output** — because the template's decompressor head cannot relocate a 37 MB image. The crash is **before earlycon**, i.e. in the decompressor / kexec handoff.

## Isolation (what we ruled out)

1. **kpatch is clean** — changes exactly **5 bytes** on epyc7003ntb (`OR→AND` ×4 + ramdisk check), identical to SA6400. Not the cause.
2. **Stock genuine `zImage` boots fully** — kexec'ing the *unmodified* PAS7700 `zImage` reaches `[0.000000] Linux version …` and runs to 790 s uptime, stopping only at `Loading of unsigned module is rejected` (expected without kpatch). → **kernel / kexec / environment are fine.**
3. All repack variants (template, large template, and `rebuild-bzimage` in our test) fail **before earlycon** → the fault is in the repack's decompressor stage, not the kernel.

## Fix: reuse the genuine container, swap only the payload

```
genuine zImage = [ setup + decompressor | LZMA payload | tail ]
                            keep               swap        keep
```

1. Unpack genuine payload → `vmlinux`; kpatch → `vmlinux-mod` (size unchanged, 37,288,424 B).
2. Recompress `vmlinux-mod` as **lzma_alone** matching the kernel format: `xz --format=lzma -9e` → props `0x5d`, 64 MiB dict, EOS-terminated. Result **6,479,672 B ≤** original stream (6,491,203 B).
3. **Zero-pad** the new stream back to the original stream length; keep the genuine 4-byte appended size and tail.

Every offset (`payload_length`@0x24c, appended size, tail, and the decompressor's baked `z_input_len`) stays **byte-identical**; only the payload content changes. The genuine decompressor + `init_size` (44.2 MB) are already correct for this kernel (stock boot proves it), so it boots unchanged.

**Verified:** round-trips back to `vmlinux-mod` byte-for-byte via `bzImage-to-vmlinux.sh`, and **boots DSM successfully on real hardware**.

---

## Log excerpts

### ① Stock (unmodified) genuine `zImage` — boots fully, earlycon works from `[0.000000]`

```text
[    0.000000] Linux version 5.10.55+ (root@build4) (x86_64-pc-linux-gnu-gcc (GCC) 12.2.0, GNU ld (GNU Binutils) 2.38) #101188 SMP Thu May 7 23:11:13 CST 2026
[    0.000000] Command line: dsm withefi earlyprintk console=ttyS0,115200n8 ... earlycon=uart8250,io,0x3f8,115200n8 ... syno_hw_version=PAS7700 panic=0 mev=vmware
[    0.000000] KERNEL supported cpus:
[    0.000000]   Intel GenuineIntel
[    0.000000]   AMD AuthenticAMD
[    0.000000]   Hygon HygonGenuine
...
[  790.503928] ...        <- ran to 790s uptime, no triple fault, no panic
```

### ② Same stock boot — only failure is unsigned-module rejection (expected, kpatch NOT applied)

```text
[   16.107429] Loading of unsigned module is rejected
[   16.107429] Loading of unsigned module is rejected
```

> This is exactly what an *unpatched* kernel does — the genuine decompressor + kernel are healthy; only the module-signature bypass (kpatch's `OR→AND` patch) is missing. Applying kpatch fixes this.

### ③ Patched `zImage` (template / large-template repack) — the failure

```text
(no serial output at all — not even the [0.000000] line above)
=> VMware: "A fault has occurred causing a virtual CPU to enter the shutdown state"
   (triple fault, before earlycon initializes)
```

> The **absence** of any output is the key signal: with an identical cmdline (same `earlycon=uart8250,io,0x3f8`), the stock kernel prints from `[0.000000]`, but the template-repacked kernel prints **nothing** → it dies in the decompressor / kexec handoff, before the main kernel runs.

### Contrast table

| Kernel image | Serial output | Result |
|---|---|---|
| Stock genuine `zImage` (unmodified) | `[0.000000]` → 790 s | Boots; only "unsigned module rejected" |
| Template repack (uncompressed, 34 MB cap) | **none** | Triple fault (truncated / decompressor mismatch) |
| Large template (uncompressed, 40 MB cap) | **none** | Triple fault (decompressor can't relocate 37 MB) |
| **Payload-recompress** (genuine decompressor + re-LZMA payload) | `[0.000000]` → full boot | **Boots DSM** ✅ |

---

## Supporting data

### ④ kpatch behaves identically on SA6400 (works) and PAS7700 (fails) — kpatch ruled out

```text
--- SA6400 (epyc7002, boots) ---          --- PAS7700 (epyc7003ntb) ---
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
bytes changed vs input: 5                  bytes changed vs input: 5
vmlinux size: unchanged (32,803,304)       vmlinux size: unchanged (37,288,424)
```

> Same patch set, same 5-byte delta, same success — only the per-kernel offsets differ. kpatch is not the problem.

### ⑤ bzImage header comparison — the template's `init_size` is too small for this kernel

| Field (offset) | Genuine PAS7700 `zImage` | `bzImage-template-v5` | SA6400 (fits) |
|---|---|---|---|
| decompressed `vmlinux` | **37,288,424** | — | 32,803,304 |
| `payload_length` (0x24c) | 6,491,207 (LZMA) | 34,448,864 (raw) | — |
| **`init_size` (0x260)** | **44,195,840** | **34,918,400** | — |
| template payload capacity | — | 34,448,860 | — |

> The template's decompressor was built with `init_size` 34.9 MB and a ~34 MB payload window. The PAS7700 kernel needs **`init_size` 44.2 MB** and a 37.3 MB image — it does not fit, and even a size-extended template keeps the small decompressor's assumptions.

### ⑥ Repack round-trip verification (payload-recompress method)

```text
$ vmlinux-to-bzImage-recompress.sh vmlinux-mod  genuine-zImage  out.zImage
   xz --format=lzma -9e  ->  stream 6,479,672 B  (<= original 6,491,203, header 5d 00 00 00 04 ff..ff)
   zero-pad to 6,491,203 + 4-byte size  ->  payload 6,491,207 (identical)
   out.zImage = 6,523,248 B   payload_length=6,491,207   init_size=44,195,840   (all byte-identical to genuine)

$ bzImage-to-vmlinux.sh out.zImage  vmlinux.roundtrip
   vmlinux.roundtrip == vmlinux-mod   ->  MATCH  (kpatch's 5 bytes preserved)
```

> The re-LZMA'd payload is smaller than the original, so zero-padding restores the exact stream length. Every structural offset stays identical; only the payload content changes. Confirmed to round-trip and to boot DSM on real hardware.

---

## Note on `rebuild-bzimage`

Since the stock kernel boots, a correct full rebuild should also work in principle — but in our test the `rebuild-bzimage` path still triple-faulted for epyc7003ntb. Worth checking whether it correctly handles a 37 MB / `init_size` 44 MB kernel (e.g. `z_output_len` / relocation-buffer sizing). The payload-swap above is a minimal, offset-preserving alternative that reuses the genuine decompressor verbatim.

## Environment caveat

Recompression needs a **real xz** — BusyBox `xz`/`lzma` are decompress-only. On TinyCore, ensure `xz.tcz` (xz 5.2.5) is loaded or bundle a static xz.
