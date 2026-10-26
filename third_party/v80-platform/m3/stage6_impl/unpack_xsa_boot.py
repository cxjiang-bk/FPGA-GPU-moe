#!/usr/bin/env python3
"""Recover Bootgen inputs omitted by SDTGen, from this validated XSA only."""
from pathlib import Path
import json,re,sys,zipfile
xsa=Path(sys.argv[1]).resolve();sdt=Path(sys.argv[2]).resolve()
out=sdt/'m3_hw_handoff';out.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(xsa) as z:
    assert z.testzip() is None
    names=set(z.namelist())
    for name in names:
        target=(out/name).resolve()
        assert target.is_relative_to(out.resolve()),name
        if name.endswith('/'):continue
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(z.read(name))
    changes=[]
    text=z.read('M3_boot.bif').decode()
    def relocate(m):
        original=m[1]
        relative=original.split('/xsa/',1)[-1] if '/xsa/' in original else original
        assert relative in names,original
        changes.append({'original':original,'relative':relative})
        return 'file = '+relative
    text=re.sub(r'file\s*=\s*([^\s,}]+)',relocate,text)
    assert changes
    (out/'M3_boot.bif').write_text(text)
    target=sdt/'M3_boot.pdi';data=z.read('M3_boot.pdi')
    if target.exists():assert target.read_bytes()==data,'Existing SDT boot image differs before overlay'
    else:target.write_bytes(data)
    (out/'path_relocations.json').write_text(json.dumps(changes,indent=2)+'\n')
print('Recovered XSA Bootgen inputs; all BIF file references resolved within the extraction directory')
