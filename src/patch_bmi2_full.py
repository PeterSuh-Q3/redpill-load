"""
patch_bmi2_full.py — Patch ALL BMI2 instructions in entire EXEC segment.
Extends patch_bmi2.py (which only covered first 64KB).
Input : /tmp/p1b/zImage  (already has first 64KB patched, 0 BMI2 there)
Output: /tmp/zImage-fullpatched
"""

import re, struct, sys, shutil, os

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

# ---- encoders (same as patch_bmi2.py) ----
def push_r(r):
    return bytes([0x41, 0x50+(r-8)]) if r>=8 else bytes([0x50+r])
def pop_r(r):
    return bytes([0x41, 0x58+(r-8)]) if r>=8 else bytes([0x58+r])

def mov_rr(dst, src, W):
    if dst==src: return b""
    need = W or dst>=8 or src>=8
    rex = 0x40|(W<<3)|((src>=8)<<2)|(dst>=8)
    modrm = 0xC0|((src&7)<<3)|(dst&7)
    return bytes([rex,0x89,modrm]) if need else bytes([0x89,modrm])

def mov_r_mem(dst, base, mod, disp, W):
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(base>=8)
    modrm = (mod<<6)|((dst&7)<<3)|(base&7)
    buf = bytearray()
    if rex != 0x40 or W: buf.append(rex)
    buf.append(0x8B)
    if (base&7)==4: buf.append(modrm); buf.append(0x24)
    else:           buf.append(modrm)
    if   mod==1: buf.append(disp&0xFF)
    elif mod==2: buf+=struct.pack("<i",disp)
    return bytes(buf)

def mov_cl_reg(src):
    if src==1: return b""
    if src<4:  return bytes([0x88, 0xC0|(src<<3)|1])
    if src<8:  return bytes([0x40,0x88,0xC0|(src<<3)|1])
    return bytes([0x41,0x8A,0xC0|(1<<3)|(src&7)])

def shift_cl(mnem, dst, W):
    ext={"SHLX":4,"SHRX":5,"SARX":7}[mnem]
    if W:
        return bytes([0x48|(dst>=8),0xD3,0xC0|(ext<<3)|(dst&7)])
    else:
        return (bytes([0x41,0xD3,0xC0|(ext<<3)|(dst&7)]) if dst>=8
                else bytes([0xD3,0xC0|(ext<<3)|dst]))

def make_trampoline(info):
    mnem=info["mnem"]; W=info["W"]; dst=info["dst_idx"]
    src_mem=info["src_is_mem"]; src=info["src_idx"]; count=info["count_idx"]
    mem_mod=info.get("mem_mod",0); mem_disp=info.get("mem_disp",0)
    code=bytearray()
    if count==1:
        if not src_mem: code+=mov_rr(dst,src,W)
        else:           code+=mov_r_mem(dst,src,mem_mod,mem_disp,W)
        code+=shift_cl(mnem,dst,W)
    elif count==dst:
        code+=push_r(1)
        code+=mov_cl_reg(count)
        if not src_mem:
            if src!=dst: code+=mov_rr(dst,src,W)
        else: code+=mov_r_mem(dst,src,mem_mod,mem_disp,W)
        code+=shift_cl(mnem,dst,W)
        code+=pop_r(1)
    elif dst==1:
        code+=push_r(0)
        if not src_mem: code+=mov_rr(0,src,W)
        else:           code+=mov_r_mem(0,src,mem_mod,mem_disp,W)
        code+=mov_cl_reg(count)
        code+=shift_cl(mnem,0,W)
        code+=mov_rr(1,0,W)
        code+=pop_r(0)
    else:
        code+=push_r(1)
        code+=mov_cl_reg(count)
        if not src_mem: code+=mov_rr(dst,src,W)
        else:           code+=mov_r_mem(dst,src,mem_mod,mem_disp,W)
        code+=shift_cl(mnem,dst,W)
        code+=pop_r(1)
    code+=bytes([0xC3])
    return bytes(code)

def decode_bmi2(buf):
    if buf[0]!=0xC4: return None
    b1,b2,op=buf[1],buf[2],buf[3]
    R=1-((b1>>7)&1); X=1-((b1>>6)&1); B=1-((b1>>5)&1)
    mmap=b1&0x1f; W=(b2>>7)&1; vvvv=(~b2>>3)&0xf
    L=(b2>>2)&1; pp=b2&3
    BMI2={(2,2,0xF7):"SARX",(2,3,0xF7):"SHRX",(2,1,0xF7):"SHLX",
          (2,0,0xF7):"BZHI",(2,2,0xF5):"PEXT",(2,3,0xF5):"PDEP",
          (2,2,0xF6):"MULX",(3,2,0xF0):"RORX"}
    mnem=BMI2.get((mmap,pp,op))
    if not mnem: return None
    modrm=buf[4]; mod=modrm>>6
    reg=((modrm>>3)&7)|(R<<3); rm=(modrm&7)|(B<<3)
    length=5; mem_mod=mem_disp=0; src_is_mem=False
    if mod==3:
        src_is_mem=False; src_idx=rm
    else:
        src_is_mem=True; src_idx=rm
        if (rm&7)==4: length+=1
        if   mod==1: mem_disp=struct.unpack_from("b",buf,length)[0]; length+=1
        elif mod==2: mem_disp=struct.unpack_from("<i",buf,length)[0]; length+=4
        elif mod==0 and (rm&7)==5: mem_disp=struct.unpack_from("<i",buf,length)[0]; length+=4
        mem_mod=mod
    if mnem=="RORX": length+=1
    return dict(mnem=mnem,W=W,dst_idx=reg,src_is_mem=src_is_mem,
                src_idx=src_idx,count_idx=vvvv,
                mem_mod=mem_mod,mem_disp=mem_disp,length=length)

# ---- main ----
IN  = "/tmp/p1b/zImage"    # already has first 64KB patched
OUT = "/tmp/zImage-fullpatched"
shutil.copy2(IN, OUT)
data = bytearray(open(OUT,"rb").read())

setup_sects    = data[0x1f1]
kernel_offset  = (setup_sects+1)*512
payload_off    = u32(data,0x248)
elf_base       = kernel_offset+payload_off

elf = memoryview(data)[elf_base:]
e_phoff = u64(elf,0x20)
e_phnum = struct.unpack_from("<H",elf,0x38)[0]

text_vaddr=text_foff_elf=text_fsz=None
for i in range(e_phnum):
    b=e_phoff+i*56
    if u32(elf,b)==1 and u32(elf,b+4)&1:
        text_vaddr  = u64(elf,b+16)
        text_foff_elf=u64(elf,b+8)
        text_fsz    = u64(elf,b+32)
        break
text_foff_z = elf_base + text_foff_elf

print("text: vaddr=0x%016x  size=0x%08x (%dMB)" % (text_vaddr,text_fsz,text_fsz//1024//1024))

# Trampoline area (2MB int3 block)
TRAMP_VADDR  = 0xffffffff818014aa
TRAMP_FOFF_Z = elf_base + 0x00a014aa
TRAMP_MAX    = 2091862

# Resume after first-pass 313 bytes
TRAMP_USED_PREV = 313   # from patch_bmi2.py first pass
tramp_ptr  = TRAMP_FOFF_Z + TRAMP_USED_PREV
tramp_vptr = TRAMP_VADDR  + TRAMP_USED_PREV

# Scan FULL segment (skip first 64KB which is already patched)
region = bytes(data[text_foff_z:text_foff_z+text_fsz])
pat = re.compile(b"\xc4[\xe2\xe3][\x00-\xff][\xf0\xf5\xf6\xf7]")
hits = list(pat.finditer(region))

print("BMI2 remaining in full segment: %d (skipping first 64KB)" % len(hits))
print("  (first 64KB should be 0 = already patched)")

ok=fail=skip=0
for m in hits:
    rel_off = m.start()
    if rel_off < 65536:  # already patched, should be 0
        continue
    z_off   = text_foff_z + rel_off
    site_va = text_vaddr  + rel_off
    buf     = region[rel_off:rel_off+16]
    info    = decode_bmi2(buf)
    if not info:
        skip+=1; continue
    insn_len = info["length"]
    try:
        tb = make_trampoline(info)
    except Exception as e:
        print("SKIP trampoline error at 0x%016x: %s" % (site_va,e))
        skip+=1; continue
    if tramp_ptr+len(tb) > TRAMP_FOFF_Z+TRAMP_MAX:
        print("ERROR: trampoline area full at 0x%016x" % site_va)
        sys.exit(1)
    data[tramp_ptr:tramp_ptr+len(tb)] = tb
    rel32 = struct.unpack("<i",struct.pack("<I",(tramp_vptr-(site_va+5))&0xFFFFFFFF))[0]
    patch = bytearray([0xE8])+struct.pack("<i",rel32)+bytes([0x90])*(insn_len-5)
    data[z_off:z_off+insn_len] = patch
    tramp_ptr  += len(tb)
    tramp_vptr += len(tb)
    ok+=1

with open(OUT,"wb") as f: f.write(data)

# Verify: re-scan should show 0 BMI2 in entire segment
verify = open(OUT,"rb").read()
seg = verify[text_foff_z:text_foff_z+text_fsz]
remaining = len(list(pat.finditer(seg)))

print("\n=== RESULT ===")
print("Newly patched : %d" % ok)
print("Skipped       : %d" % skip)
print("Trampoline used: %d bytes total" % (tramp_ptr-TRAMP_FOFF_Z))
print("BMI2 remaining in segment: %d (should be 0)" % remaining)
print("Output: %s  MD5: " % OUT, end="")
import hashlib
print(hashlib.md5(open(OUT,"rb").read()).hexdigest())
