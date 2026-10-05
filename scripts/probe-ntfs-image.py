#!/usr/bin/env python3
"""只在新建临时目录中操作普通文件；不接受设备或目标路径参数，不挂载。
工具源码及构建留在 .workbench，不随客户端捆绑。
"""
import hashlib, json, pathlib, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.workbench/ntfs-3g-2026.7.7/ntfsprogs'
report = {'engine': 'NTFS-3G 2026.7.7', 'scope': '离线可丢弃镜像；不是 Finder 挂载验证', 'checks': [],
          'not_covered': ['Finder 挂载', '重命名', '移动', '删除', '卸载重挂', 'Windows 交叉读取和 chkdsk', '异常断电', '休眠/dirty 风险检测']}

def run(tool, *args):
    result = subprocess.run([str(TOOLS / tool), *map(str, args)], capture_output=True, timeout=40, check=False)
    if result.returncode:
        raise RuntimeError(f'{tool} failed ({result.returncode}): {result.stderr.decode(errors="replace")[:1200]}')
    return result.stdout

with tempfile.TemporaryDirectory(prefix='volisle-ntfs-', dir=ROOT / '.workbench') as temporary:
    folder = pathlib.Path(temporary)
    image = folder / 'disposable.img'
    # x 模式禁止覆盖；文件从未 attach 为系统块设备。
    with image.open('xb') as handle:
        handle.truncate(64 * 1024 * 1024)
    assert image.is_file() and not image.is_symlink()
    run('mkntfs', '-F', '-Q', '-L', 'VOLISLE_TEST', image)
    report['checks'].append({'name': '创建 64 MiB NTFS 普通文件镜像', 'passed': True})
    for name, payload in [('/hello.txt', b'Volisle isolated NTFS probe\n'),
                          ('/中文 空格 💽.txt', '盘屿：中文与 Emoji\n'.encode()),
                          ('/' + '长' * 100 + '.txt', b'long filename'),
                          ('/batch.bin', bytes(range(256)) * 16384)]:
        source = folder / 'payload.bin'
        source.write_bytes(payload)
        run('ntfscp', image, source, name)
        observed = run('ntfscat', image, name)
        expected_hash = hashlib.sha256(payload).hexdigest()
        actual_hash = hashlib.sha256(observed).hexdigest()
        if expected_hash != actual_hash: raise RuntimeError('哈希不一致')
        # 新进程重新打开同一镜像再次读取；这不是系统卸载重挂。
        reopened = run('ntfscat', image, name)
        if reopened != payload: raise RuntimeError('重新打开镜像后内容不一致')
        report['checks'].append({'name': name, 'bytes': len(payload), 'sha256': actual_hash, 'passed': True})
    report['checks'].append({'name': 'NTFS 根目录枚举', 'passed': bool(run('ntfsls', image))})
report['temporary_image_removed'] = not image.exists()
report['executed_at'] = time.strftime('%Y-%m-%d %H:%M:%S %z')
output = ROOT / 'docs/testing/ntfs-image-result.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(output.relative_to(ROOT))
print('通过：离线镜像创建、写入、独立进程读取与 SHA-256；未验证 Finder 和 Windows。')
