"""
patch_bmi1.py — Patch BMI1 BLSR/BLSMSK/BLSI instructions (C4 E2 xx F3)
Input : /tmp/zImage-andnpatched  (BMI2 3176 + ANDN 403 patched)
Output: /tmp/zImage-bmi1patched

VEX3 encoding:
  C4 [R~X~B~ 00010] [W ~vvvv~ 0 00] F3 ModRM [SIB] [disp]
  dst  = vvvv (inverted)
  src  = ModRM.r/m (reg or mem)
  ModRM.reg selects instruction: 1=BLSR, 2=BLSMSK, 3=BLSI

BLSR  dst, src  → dst = src & (src-1)   ; reset lowest set bit
BLSMSK dst, src → dst = src ^ (src-1)   ; mask up to and incl lowest set bit
BLSI  dst, src  → dst = src & (-src)    ; isolate lowest set bit
"""

import re, struct, sys, shutil, hashlib

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

def push_r(r):
    return bytes([0x41, 0x50+(r-8)]) if r>=8 else bytes([0x50+r])
def pop_r(r):
    return bytes([0x41, 0x58+(r-8)]) if r>=8 else bytes([0x58+r])

def mov_rr(dst, src, W):
    if dst == src: return b""
    rex = 0x40|(W<<3)|((src>=8)<<2)|(dst>=8)
    modrm = 0xC0|((src&7)<<3)|(dst&7)
    return bytes([rex, 0x89, modrm])

def mov_r_mem(dst, base, mod, disp, W):
    """MOV dst, [base+disp]"""
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(base>=8)
    modrm = (mod<<6)|((dst&7)<<3)|(base&7)
    buf = bytearray()
    if rex != 0x40 or W: buf.append(rex)
    buf.append(0x8B)
    if (base&7)==4: buf.append(modrm); buf.append(0x24)
    else:           buf.append(modrm)
    if   mod==1: buf.append(disp & 0xFF)
    elif mod==2: buf += struct.pack("<i", disp)
    elif mod==0 and (base&7)==5: buf += struct.pack("<i", disp)
    return bytes(buf)

def neg_r(r, W):
    """NEG r"""
    if W:
        rex = 0x48 | (r >= 8)
        return bytes([rex, 0xF7, 0xD8 | (r & 7)])
    else:
        if r >= 8: return bytes([0x41, 0xF7, 0xD8 | (r & 7)])
        else:      return bytes([0xF7, 0xD8 | r])

def dec_r(r, W):
    """DEC r"""
    if W:
        rex = 0x48 | (r >= 8)
        return bytes([rex, 0xFF, 0xC8 | (r & 7)])
    else:
        if r >= 8: return bytes([0x41, 0xFF, 0xC8 | (r & 7)])
        else:      return bytes([0xFF, 0xC8 | r])

def and_rr(dst, src, W):
    """AND dst, src"""
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(src>=8)
    modrm = 0xC0|((dst&7)<<3)|(src&7)
    return bytes([rex, 0x23, modrm])

def xor_rr(dst, src, W):
    """XOR dst, src"""
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(src>=8)
    modrm = 0xC0|((dst&7)<<3)|(src&7)
    return bytes([rex, 0x33, modrm])

def decode_bmi1_f3(buf):
    """Decode BLSR/BLSMSK/BLSI: C4 E2 xx F3 /r"""
    if buf[0] != 0xC4: return None
    b1, b2, op = buf[1], buf[2], buf[3]
    if op != 0xF3: return None
    mmap = b1 & 0x1f
    if mmap != 2: return None          # 0F38 map
    pp = b2 & 3
    if pp != 0: return None
    B = 1 - ((b1>>5)&1)
    W = (b2>>7) & 1
    vvvv = (~b2>>3) & 0xf              # dst register
    modrm = buf[4]
    mod = modrm >> 6
    sel = (modrm>>3) & 7               # 1=BLSR, 2=BLSMSK, 3=BLSI
    rm  = (modrm&7) | (B<<3)          # src
    name = {1:"BLSR", 2:"BLSMSK", 3:"BLSI"}.get(sel)
    if not name: return None
    length = 5
    mem_mod = mem_disp = 0
    src_is_mem = False
    if mod == 3:
        src_is_mem = False; src_idx = rm
    else:
        src_is_mem = True; src_idx = rm
        if (rm&7)==4: length += 1
        if   mod==1: mem_disp = struct.unpack_from("b", buf, length)[0]; length += 1
        elif mod==2: mem_disp = struct.unpack_from("<i", buf, length)[0]; length += 4
        elif mod==0 and (rm&7)==5: mem_disp = struct.unpack_from("<i", buf, length)[0]; length += 4
        mem_mod = mod
    return dict(mnem=name, W=W, dst=vvvv,
                src_is_mem=src_is_mem, src=src_idx,
                mem_mod=mem_mod, mem_disp=mem_disp, length=length)

def pick_tmp(dst, src, src_is_mem):
    used = {dst, 4}   # 4=RSP always forbidden
    if not src_is_mem: used.add(src)
    for r in [0,1,2,3,5,6,7,8,9,10,11]:
        if r not in used: return r
    raise RuntimeError("No free register, used=%s" % used)

def load_src(tmp, info):
    """Return bytes to load src into tmp register."""
    if not info["src_is_mem"]:
        return mov_rr(tmp, info["src"], info["W"])
    else:
        return mov_r_mem(tmp, info["src"], info["mem_mod"], info["mem_disp"], info["W"])

def make_blsr_trampoline(info):
    """BLSR dst, src  →  dst = src & (src-1)"""
    W = info["W"]; dst = info["dst"]
    tmp = pick_tmp(dst, info["src"], info["src_is_mem"])
    code = bytearray()
    code += push_r(tmp)
    code += load_src(tmp, info)    # tmp = src
    code += mov_rr(dst, tmp, W)   # dst = src
    code += dec_r(dst, W)          # dst = src - 1
    code += and_rr(dst, tmp, W)   # dst = (src-1) & src
    code += pop_r(tmp)
    code += b"\xC3"
    return bytes(code)

def make_blsmsk_trampoline(info):
    """BLSMSK dst, src  →  dst = src ^ (src-1)"""
    W = info["W"]; dst = info["dst"]
    tmp = pick_tmp(dst, info["src"], info["src_is_mem"])
    code = bytearray()
    code += push_r(tmp)
    code += load_src(tmp, info)    # tmp = src
    code += mov_rr(dst, tmp, W)   # dst = src
    code += dec_r(dst, W)          # dst = src - 1
    code += xor_rr(dst, tmp, W)   # dst = (src-1) ^ src
    code += pop_r(tmp)
    code += b"\xC3"
    return bytes(code)

def make_blsi_trampoline(info):
    """BLSI dst, src  →  dst = src & (-src)"""
    W = info["W"]; dst = info["dst"]
    tmp = pick_tmp(dst, info["src"], info["src_is_mem"])
    code = bytearray()
    code += push_r(tmp)
    code += load_src(tmp, info)    # tmp = src
    code += mov_rr(dst, tmp, W)   # dst = src
    code += neg_r(tmp, W)          # tmp = -src
    code += and_rr(dst, tmp, W)   # dst = src & (-src)
    code += pop_r(tmp)
    code += b"\xC3"
    return bytes(code)

MAKE = {"BLSR": make_blsr_trampoline,
        "BLSMSK": make_blsmsk_trampoline,
        "BLSI": make_blsi_trampoline}

# ---- main ----
IN  = "/tmp/zImage-andnpatched"
OUT = "/tmp/zImage-bmi1patched"
shutil.copy2(IN, OUT)
data = bytearray(open(OUT, "rb").read())

setup_sects   = data[0x1f1]
kernel_offset = (setup_sects+1)*512
payload_off   = u32(data, 0x248)
elf_base      = kernel_offset + payload_off
elf = memoryview(data)[elf_base:]
e_phoff = u64(elf, 0x20)
e_phnum = struct.unpack_from("<H", elf, 0x38)[0]
for i in range(e_phnum):
    b = e_phoff + i*56
    if u32(elf,b)==1 and u32(elf,b+4)&1:
        text_vaddr=u64(elf,b+16); text_foff_elf=u64(elf,b+8); text_fsz=u64(elf,b+32); break
text_foff_z = elf_base + text_foff_elf
print("text: vaddr=0x%016x  size=0x%08x" % (text_vaddr, text_fsz))

TRAMP_VADDR  = 0xffffffff818014aa
TRAMP_FOFF_Z = elf_base + 0x00a014aa
TRAMP_MAX    = 2091862
TRAMP_USED_PREV = 34874  # after BMI2 + ANDN patches

tramp_ptr  = TRAMP_FOFF_Z + TRAMP_USED_PREV
tramp_vptr = TRAMP_VADDR  + TRAMP_USED_PREV
assert data[tramp_ptr] == 0xCC, "Trampoline not clear at offset %d" % TRAMP_USED_PREV

region = bytes(data[text_foff_z:text_foff_z+text_fsz])
pat = re.compile(b"\xc4\xe2[\x00-\xff]\xf3")
hits = list(pat.finditer(region))
print("BLSI/BLSMSK/BLSR candidates: %d" % len(hits))

ok = fail = skip = 0
for m in hits:
    rel_off = m.start()
    z_off   = text_foff_z + rel_off
    site_va = text_vaddr  + rel_off
    buf     = region[rel_off:rel_off+16]
    info    = decode_bmi1_f3(buf)
    if not info:
        skip += 1; continue
    insn_len = info["length"]
    if insn_len < 5:
        print("  SKIP short at 0x%016x" % site_va)
        skip += 1; continue
    try:
        tb = MAKE[info["mnem"]](info)
    except Exception as e:
        print("  SKIP error at 0x%016x: %s" % (site_va, e))
        skip += 1; continue
    if tramp_ptr + len(tb) > TRAMP_FOFF_Z + TRAMP_MAX:
        print("ERROR: trampoline area full"); sys.exit(1)
    data[tramp_ptr:tramp_ptr+len(tb)] = tb
    rel32 = struct.unpack("<i", struct.pack("<I", (tramp_vptr-(site_va+5))&0xFFFFFFFF))[0]
    patch = bytearray([0xE8]) + struct.pack("<i", rel32) + bytes([0x90])*(insn_len-5)
    data[z_off:z_off+insn_len] = patch
    tramp_ptr  += len(tb)
    tramp_vptr += len(tb)
    ok += 1

with open(OUT, "wb") as f: f.write(data)

verify = open(OUT,"rb").read()
seg = verify[text_foff_z:text_foff_z+text_fsz]
remaining = len(list(pat.finditer(seg)))

print("\n=== RESULT ===")
print("Patched BLSR/BLSMSK/BLSI: %d" % ok)
print("Skipped : %d" % skip)
print("Trampoline used total: %d bytes" % (tramp_ptr - TRAMP_FOFF_Z))
print("BMI1-F3 remaining: %d (should be 0)" % remaining)
print("Output MD5:", hashlib.md5(open(OUT,"rb").read()).hexdigest())
