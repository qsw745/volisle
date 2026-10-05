#!/usr/bin/env python3
"""Reattach fresh owned images; never accepts a user-supplied disk or image."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.workbench/reconnect-20260925'


def run(args):
    return subprocess.run([str(x) for x in args],check=True,capture_output=True,timeout=60)


def sha(image):
    return hashlib.sha256(image.read_bytes()).hexdigest()


def attach(image):
    reply = plistlib.loads(run(['hdiutil','attach','-nomount','-nobrowse','-noautoopen','-imagekey','diskimage-class=CRawDiskImage','-plist',image]).stdout)
    names = [x['dev-entry'] for x in reply['system-entities'] if 'dev-entry' in x]
    assert len(names) == 1
    return names[0]


def detach(image,device):
    reply = plistlib.loads(run(['hdiutil','info','-plist']).stdout)
    owned = [x for x in reply['images'] if Path(x.get('image-path','')).resolve()==image.resolve()]
    assert len(owned)==1
    assert [x['dev-entry'] for x in owned[0]['system-entities'] if 'dev-entry' in x]==[device]
    run(['hdiutil','detach',device])


def test_phase(folder,image,phase,mode,baseline,boot):
    device = attach(image)
    try:
        info = plistlib.loads(run(['diskutil','info','-plist',device]).stdout)
        assert info['TotalSize']==64*1024*1024 and info['Writable'] is True and not info.get('Mounted',False)
        manifest = folder/'fixture.json'
        manifest.write_text(json.dumps({'image':str(image),'bsdName':device.removeprefix('/dev/'),
            'phase':phase,'mode':mode,'baselineSHA256':baseline,'bootSHA256':boot}))
        env = os.environ.copy(); env['VOLISLE_RECONNECT_FIXTURE']=str(manifest)
        with (folder/(phase+'.log')).open('wb') as log:
            child = subprocess.Popen(['swift','test','--package-path','packages/VolisleCore','-Xswiftc','-DVOLISLE_BLOCK_JOURNAL_TESTING',
                '--filter','NativeRecoveryReconnectTests'],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                code=child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGTERM); child.wait(timeout=15); raise
        text=(folder/(phase+'.log')).read_text()
        assert code==0 and 'reconnectUsesStoredAuthenticatedIdentity() passed' in text and 'skipped' not in text.lower(), str(folder/(phase+'.log'))
    finally:
        detach(image,device)
    return device


def scenario(mode):
    folder=Path(tempfile.mkdtemp(prefix='native-write-reconnect-',dir=ROOT/'.workbench'))
    original=folder/'original.img'
    with original.open('xb') as stream: stream.truncate(64*1024*1024)
    run([ROOT/'.workbench/ntfs-3g-2026.7.7/ntfsprogs/mkntfs','-F','-Q','-L','Volisle Reconnect',original])
    baseline=sha(original); boot=hashlib.sha256(original.read_bytes()[:512]).hexdigest()
    with original.open('r+b') as stream:
        stream.seek(16*1024*1024); assert stream.read(4096)==bytes(4096)
        stream.seek(16*1024*1024); stream.write(bytes([0xa5])*4096); stream.flush(); os.fsync(stream.fileno())
    interrupted=sha(original)
    first=test_phase(folder,original,'prepare',mode,baseline,boot)
    assert sha(original)==interrupted
    image=original
    if mode=='clone':
        image=folder/'clone.img'; shutil.copyfile(original,image)
        assert sha(image)==interrupted and image.stat().st_ino!=original.stat().st_ino
    if mode=='foreign-edit':
        with image.open('r+b') as stream:
            stream.seek(24*1024*1024); assert stream.read(512)==bytes(512)
            stream.seek(24*1024*1024); stream.write(bytes([0x6b])*512); stream.flush(); os.fsync(stream.fileno())
    before_restore=sha(image)
    decoy=folder/'number-reservation.img'; decoy_device=None
    try:
        if mode=='renumbered':
            with decoy.open('xb') as stream: stream.truncate(64*1024*1024)
            decoy_device=attach(decoy)
        second=test_phase(folder,image,'restore',mode,baseline,boot)
        if mode=='renumbered': assert first!=second
    finally:
        if decoy_device: detach(decoy,decoy_device)
    if decoy.exists(): decoy.unlink()
    final=sha(image)
    assert final==(baseline if mode in ['same','renumbered'] else before_restore)
    prepared=json.loads((folder/'prepared.json').read_text()); restored=json.loads((folder/'restored.json').read_text())
    assert prepared['registry']!=restored['registry']
    result={'mode':mode,'passed':True,'folder':str(folder),'firstDevice':first,'secondDevice':second,
        'registryChanged':True,'identityMatched':prepared['identity']==restored['identity'],
        'baselineSHA256':baseline,'beforeRestoreSHA256':before_restore,'finalSHA256':final,
        'normalDetachCompleted':True,'physicalDiskTouched':False,'prepared':prepared,'restored':restored}
    (folder/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    original.unlink()
    if image!=original: image.unlink()
    print(json.dumps(result),flush=True)
    return result


def main():
    OUT.mkdir(exist_ok=True)
    results=[scenario(mode) for mode in ['same','clone','foreign-edit','renumbered']]
    (OUT/'reconnect-result.json').write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__': main()
