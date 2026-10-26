#!/usr/bin/env python3
"""Select the validated XSA's exact image pair, preserving the first export."""
from pathlib import Path
import hashlib,json,shutil,sys,zipfile
run=Path(sys.argv[1]).resolve();a=run/'artifacts'
assert (run/'IMAGE_EXPORT_COMPLETE').exists()
log=(run/'package_logs/export_console.log').read_text()
assert 'Finished running validate_hw_platform' in log and '# exit 0' in log
assert 'Writing PDI files for non-project flow XSA:' in log
def digest(data):return {'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
record={'reason':'write_hw_platform regenerated its internal PDI from the open routed design; first standalone export differs.',
        'selected_source':'Validated M3.xsa pair; temporary WDI files are removed by Vivado after export',
        'source_checkpoint_sha256':hashlib.sha256((run/'checkpoints/m3_routed.dcp').read_bytes()).hexdigest(),
        'xsa':digest((a/'M3.xsa').read_bytes()),'images':{}}
with zipfile.ZipFile(a/'M3.xsa') as z:
    assert z.testzip() is None
    sysdef=z.read('sysdef.xml').decode()
    assert 'PART="xcv80-lsva4737-2MHP-e-S"' in sysdef
    assert '<HIERARCHY Name="m3_lpumem_wrapper"/>' in sysdef
    assert 'Type="PL_PDI" Name="M3_pld.pdi"' in sysdef
    wdi=z.read('wdi_info.xml').decode()
    assert str(a/'.Xil') in wdi and '/xsa/M3_boot.bif' in wdi and '/xsa/M3_pld.bif' in wdi
    with zipfile.ZipFile(run/'checkpoints/m3_routed.dcp') as checkpoint:
        assert z.read('M3.nts')==checkpoint.read('m3_lpumem_wrapper.nts'), 'NoC traffic differs from routed checkpoint'
    record['noc_traffic_matches_routed_checkpoint']=True
    record['wdi_info']=wdi
    selected={}
    for kind in ['boot','pld']:
        name=f'M3_{kind}.pdi';data=z.read(name)
        generated=list((a/'.Xil').glob(f'*/xsa/{name}'))
        if generated:
            assert len(generated)==1,generated
            assert generated[0].read_bytes()==data,'XSA differs from its own routed WDI output'
        old=(a/name).read_bytes()
        record['images'][kind]={'initial_export':digest(old),'xsa_export':digest(data),
                                'identical':old==data,'generated_source':str(generated[0]) if generated else 'XSA embedded file; temporary source cleaned by Vivado'}
        selected[name]=data
    archive=a/'initial_export';archive.mkdir(exist_ok=True)
    for name,data in selected.items():
        old_path=archive/name
        if old_path.exists():assert old_path.read_bytes()==(a/name).read_bytes(),'Refuse to replace an existing archive'
        else:shutil.copy2(a/name,old_path)
        (a/name).write_bytes(data)
(run/'image_export_reconciliation.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
