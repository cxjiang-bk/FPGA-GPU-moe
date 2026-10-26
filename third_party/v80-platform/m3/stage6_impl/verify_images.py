#!/usr/bin/env python3
"""Verify exact XSA image contents and AMR BOOT/PLD identity, offline only."""
from pathlib import Path
import hashlib, json, re, struct, sys, zipfile

run = Path(sys.argv[1]).resolve()
stage = sys.argv[2]
a = run / 'artifacts'
def digest(p):
    data = p.read_bytes()
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

checks = {}
with zipfile.ZipFile(a/'M3.xsa') as z:
    assert z.testzip() is None, 'Corrupt XSA'
    for kind in ('boot','pld'):
        names = [n for n in z.namelist() if n.endswith(f'_{kind}.pdi')]
        assert len(names)==1, names
        data = z.read(names[0])
        assert data == (a/f'M3_{kind}.pdi').read_bytes(), f'XSA {kind} image differs'
        checks[kind] = digest(a/f'M3_{kind}.pdi')
(run/'xsa_verification.json').write_text(json.dumps(dict(status='PASS', images=checks),indent=2)+'\n')
if stage == 'xsa':
    print('XSA PDI byte comparison: PASS')
    sys.exit(0)

def header(text, name):
    m = re.search(r'IMAGE HEADER \('+re.escape(name)+r'\)(.*?)(?=\n   IMAGE HEADER|\n   PARTITION HEADER|\Z)',text,re.S)
    assert m, name
    result = {}
    for k in ('id','unique_id','parent_unique_id'):
        v = re.search(r'(?<![\w_])'+k+r' \(0x[0-9a-f]+\)\s*:\s*(0x[0-9a-f]+)',m[1])
        assert v,k
        result[k]=int(v[1],16)
    return result

logs=run/'package_logs'
boot_text=(logs/'boot_headers.txt').read_text()
pld_text=(logs/'pld_headers.txt').read_text()
complete_text=(logs/'boot_amc_headers.txt').read_text()
b=header(boot_text,'CONFIG_MASTER');p=header(pld_text,'CONFIG_MASTER');c=header(complete_text,'CONFIG_MASTER')
assert b['id']==0x18700000 and p['id']==0x18700001
assert b['unique_id'] and b['unique_id']==p['parent_unique_id']==c['unique_id']
assert header(complete_text,'amr_subsystem')['id']==0x1c000006
assert '[core: r5-0, type: elf]' in complete_text
assert 'id_code (0x18) : 0x14d2f093' in complete_text
boot=(a/'M3.bin').read_bytes()
assert struct.unpack_from('<II',boot,0x10)==(0xAA995566,0x584C4E58)
assert boot==(run/'AMC/build_amc/amr_ospi.bin').read_bytes()
elf=(a/'amc.elf').read_bytes()
assert elf[:6]==b'\x7fELF\x01\x01' and struct.unpack_from('<H',elf,18)[0]==40
assert elf==(run/'AMC/build_amc/amc.elf').read_bytes()
protected=json.loads((run/'protected_sources.json').read_text())
assert not [p for p,h in protected.items() if hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h], 'Protected input changed'
result=dict(status='PASS', board_programmed=False, hardware_validation='NOT_RUN',
            build=str(run),deployment_mode='MATCHED_BOOT_AND_PLD_REQUIRED',
            boot_platform_uuid=f"{b['unique_id']:032x}",pld_parent_uuid=f"{p['parent_unique_id']:032x}",
            files={name:digest(a/name) for name in ['M3.bin','M3_boot.pdi','M3_pld.pdi','M3.xsa','amc.elf']},
            existing_partition_size_check=dict(evidence='Historical FPT readback from 2026-10-17; recheck live FPT before programming.',
               current_board_verified=False,boot_capacity=0x07400000,pld_capacity=0x01700000,
               boot_fits=len(boot)<0x07400000,pld_fits=(a/'M3_pld.pdi').stat().st_size<0x01700000),
            note='Artifact consistency is separate from implementation signoff and board acceptance.')
(run/'package_verification.json').write_text(json.dumps(result,indent=2)+'\n')
(a/'SHA256SUMS').write_text(''.join(f"{v['sha256']}  {k}\n" for k,v in result['files'].items()))
print(json.dumps(result,indent=2))
