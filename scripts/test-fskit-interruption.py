#!/usr/bin/env python3
"""Kill only this app's fixture-serving process after durable writes; never touch a real disk."""
import argparse
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from bundle_manifest import sha256
from fskit_fixture import validate_fixture, WORK

spec=importlib.util.spec_from_file_location('fixture_write',Path(__file__).with_name('test-fskit-write.py'))
fixture_write=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture_write)
run=fixture_write.run


def main(folder,signed):
    fixture=validate_fixture(folder);folder=folder.resolve();image=folder/'fixture.img'
    assert not (folder/'interruption-result.json').exists()
    signing=json.loads((signed/'signing-result.json').read_text())
    assert signing['write_mode']=='fixture-only' and signing['fixture']==fixture
    relative='Contents/Extensions/VolisleFS.appex/Contents/MacOS/VolisleFS'
    executable=fixture_write.INSTALLED/relative
    assert sha256(executable)==sha256(signed/'top.qisw.volisle.app'/relative)
    run(['codesign','--verify','--deep','--strict',fixture_write.INSTALLED])
    assert not run(['/sbin/mount','-t','volisle']).stdout
    modules=json.loads(run([WORK/'probe-fskit']).stdout)['modules']
    assert len(modules)==1 and modules[0]['enabled']
    assert Path(modules[0]['path']).resolve()==executable.parents[2]
    started=datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    result={'success':False,'fixture':fixture,'sessions':[],'checks':[],'real_disk_written':False}
    original=json.loads((folder/'fixture.json').read_text())['payload_sha256']
    content=b'durable-before-extension-exit\n'*32768
    try:
        with fixture_write.mounted(image,False,result) as mountpoint:
            test=mountpoint/'durable.bin'
            with test.open('xb') as stream:
                stream.write(content);stream.flush();os.fsync(stream.fileno())
            assert test.read_bytes()==content
            assert sha256(mountpoint/fixture_write.SEED)==original
            events=json.loads(run(['/usr/bin/log','show','--start',started,'--style','json','--predicate','subsystem == "Volisle.NTFSModule"']).stdout)
            matches=[e for e in events if '实验激活参数=' in e.get('eventMessage','') and '只读=false' in e['eventMessage']]
            pids={e['processID'] for e in matches}
            assert len(pids)==1, '无法唯一绑定本轮服务进程'
            pid=pids.pop()
            command=run(['ps','-p',str(pid),'-o','comm=']).stdout.decode().strip()
            assert command==str(executable), '进程不是本应用的已核对扩展'
            assert sha256(executable)==sha256(signed/'top.qisw.volisle.app'/relative)
            # No killall, fskitd termination, forced unmount, or device removal.
            os.kill(pid,signal.SIGKILL)
            result['killed_owned_pid']=pid
            result['checks'].append('owned-fixture-process-interrupted-after-fsync')
        from ntfs_bridge_test_support import ImageIO
        inspection=ImageIO(image,readonly=True)
        try:
            result['dirty_status']=inspection.inspect()
            assert result['dirty_status']==1 and inspection.writes==0
        finally: inspection.close()
        before=sha256(image)
        assert run([WORK/'ntfs-3g-2026.7.7/ntfsprogs/ntfscat','-f',image,'/durable.bin']).stdout==content
        assert sha256(image)==before  # ntfscat opens read-only, even with dirty-volume inspection enabled.
        result['checks'].append('durable-content-preserved-independent-reader')
        with fixture_write.mounted(image,True,result) as root:
            assert (root/'durable.bin').read_bytes()==content
            assert sha256(root/fixture_write.SEED)==original
        assert sha256(image)==before
        result['checks'].append('dirty-readonly-remount-preserves-image-and-seed')
        for attempt in range(3):
            # The new activation preflight rejects dirty volumes before the
            # system exposes a writable mount. A generic attach/cleanup error
            # must not be mistaken for this expected mount refusal.
            try:
                with fixture_write.mounted(image,False,result):
                    raise AssertionError('异常退出后的脏卷意外完成可写挂载')
            except subprocess.CalledProcessError as error:
                assert error.cmd[:6]==['/sbin/mount','-F','-t','volisle','-o','volisle-rw,nosuid,nodev']
                session=result['sessions'][-1]
                assert not session.get('mounted') and session['detached'] and session['mountpoint_removed']
            assert sha256(image)==before
            with fixture_write.mounted(image,True,result) as root:
                assert not (root/'must-not-create.txt').exists()
                assert (root/'durable.bin').read_bytes()==content
                assert sha256(root/fixture_write.SEED)==original
            assert sha256(image)==before
        events=json.loads(run(['/usr/bin/log','show','--start',started,'--style','json','--predicate',
            'subsystem == "Volisle.NTFSModule"']).stdout)
        refusals=[e for e in events if e.get('eventMessage')=='挂载前只读预检状态=1'
                  and e.get('processImagePath')==str(executable)]
        assert len(refusals)>=3, '没有足够的本扩展 dirty 预检证据，不能将其他挂载错误记为通过'
        result['dirty_preflight_refusals']=len(refusals)
        result['checks'].append('repeated-dirty-mount-refusal-keeps-readonly-remount-available')
        assert sha256(image)==before
        result['checks'].append('dirty-write-refused-with-zero-image-change')
        result['success']=True
    except BaseException as error:
        result['error']=repr(error)
        raise
    finally:
        result['final_image_sha256']=sha256(image)
        (folder/'interruption-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture',type=Path,required=True)
    parser.add_argument('--signed-dir',type=Path,required=True)
    args=parser.parse_args();main(args.fixture,args.signed_dir)
