"""Per-operation WAL experiment, restricted to detached 64 MiB fixture files.

The session keeps one exclusive image lock and one append-only log. Previously
committed operations are never undone on disk. Recovery leaves a mounted NTFS
checkpoint dirty; this is NOT production recovery or permission to remount RW.
The full-image validation is intentionally unscalable and unauthenticated.
"""
import base64
import json
import os
from pathlib import Path
import re
from fixture_block_journal import (open_file, read_image, append, sha, canonical,
                                   plan_rollback, SIZE, MAX_WRITE, MAX_LOG)


def identity(fd, content):
    info = os.fstat(fd)
    return {'device': info.st_dev, 'inode': info.st_ino, 'size': SIZE,
            'bootSHA256': sha(content[:512])}


class OperationJournal:
    def __init__(self, image, journal):
        self.image = open_file(image)
        self.log = None
        self.failed = False
        self.active = None
        self.sequence = 0
        self.previous = '0' * 64
        self.commits = 0
        try:
            content = read_image(self.image)
            self.checkpoint = sha(content)
            self.log = open_file(journal, create=True)
            self.emit(dict(kind='session', schema=2, originalSHA256=self.checkpoint,
                           **identity(self.image, content)))
            directory = os.open(Path(journal).parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except BaseException:
            self.close()
            raise

    def emit(self, value):
        if self.failed:
            raise ValueError('会话已经失败')
        try:
            self.previous = append(self.log, dict(value, sequence=self.sequence, previous=self.previous))
            self.sequence += 1
        except BaseException:
            self.failed = True
            raise

    def begin(self, label):
        if self.active is not None or not isinstance(label, str) or not 0 < len(label) <= 128:
            self.failed = True
            raise ValueError('操作边界或标签无效')
        if sha(read_image(self.image)) != self.checkpoint:
            self.failed = True
            raise ValueError('事务边界外发生修改')
        self.emit({'kind': 'begin-operation', 'operation': self.commits + 1,
                   'label': label, 'originalSHA256': self.checkpoint})
        self.active = self.commits + 1

    def before_write(self, offset, data):
        if (self.active is None or type(offset) is not int or
                not 0 < len(data) <= MAX_WRITE or not 0 <= offset <= SIZE - len(data)):
            self.failed = True
            raise ValueError('未开始操作或写入范围无效')
        before = os.pread(self.image, len(data), offset)
        if len(before) != len(data):
            self.failed = True
            raise ValueError('原始块读取失败')
        self.emit({'kind': 'write', 'offset': offset, 'before': base64.b64encode(before).decode(),
                   'after': base64.b64encode(data).decode()})

    def commit(self):
        if self.active is None:
            self.failed = True
            raise ValueError('没有待提交操作')
        try:
            os.fsync(self.image)
            checkpoint = sha(read_image(self.image))
            self.emit({'kind': 'commit-operation', 'operation': self.active, 'imageSHA256': checkpoint})
        except BaseException:
            self.failed = True
            raise
        self.checkpoint = checkpoint
        self.active = None
        self.commits += 1

    def close(self):
        if self.log is not None:
            os.close(self.log)
            self.log = None
        if self.image is not None:
            os.close(self.image)
            self.image = None


def parse(fd):
    length = os.fstat(fd).st_size
    if not 0 < length <= MAX_LOG:
        raise ValueError('日志大小无效')
    data = os.pread(fd, length, 0)
    if len(data) != length or not data.endswith(b'\n'):
        raise ValueError('日志截断')
    events = []
    previous = '0' * 64
    for index, line in enumerate(data.splitlines()):
        if len(line) > 3 * MAX_WRITE:
            raise ValueError('日志记录过大')
        frame = json.loads(line)
        value = frame['payload']
        digest = sha(canonical(value))
        if (frame.get('sha256') != digest or value.get('previous') != previous or
                type(value.get('sequence')) is not int or value['sequence'] != index):
            raise ValueError('日志校验或顺序不匹配')
        events.append(value)
        previous = digest
    header = events[0]
    if header.get('kind') != 'session' or type(header.get('schema')) is not int or header['schema'] != 2:
        raise ValueError('会话日志版本无效')
    checkpoint = header.get('originalSHA256')
    if not isinstance(checkpoint, str) or not re.fullmatch('[0-9a-f]{64}', checkpoint):
        raise ValueError('会话摘要无效')
    operations = []
    active = None
    terminal = None
    for index, event in enumerate(events[1:], 1):
        kind = event.get('kind')
        if kind == 'begin-operation':
            if (active is not None or type(event.get('operation')) is not int or
                    event['operation'] != len(operations) + 1 or event.get('originalSHA256') != checkpoint):
                raise ValueError('操作提交链不连续')
            active = {'header': event, 'writes': [], 'commit': None}
            operations.append(active)
        elif kind == 'write' and active is not None:
            active['writes'].append(event)
        elif kind == 'commit-operation' and active is not None:
            if (type(event.get('operation')) is not int or event['operation'] != len(operations) or
                    not isinstance(event.get('imageSHA256'), str) or
                    not re.fullmatch('[0-9a-f]{64}', event['imageSHA256'])):
                raise ValueError('提交边界无效')
            active['commit'] = event
            checkpoint = event['imageSHA256']
            active = None
        elif kind == 'recovered' and active is not None and index == len(events) - 1:
            if event.get('imageSHA256') != checkpoint or event.get('operation') != len(operations):
                raise ValueError('恢复边界无效')
            terminal = event
        else:
            raise ValueError('未知或越界的会话事件')
    return events, operations, active, terminal, previous


def recover_session(image, journal, after_write=None):
    fd = open_file(image)
    log = None
    try:
        log = open_file(journal)
        events, operations, pending, terminal, previous = parse(log)
        current = read_image(fd)
        if any(events[0].get(key) != value for key, value in identity(fd, current).items()):
            raise ValueError('镜像身份不匹配')
        virtual = current
        target = current
        ranges = []
        # Walk all committed checkpoints in memory to validate history, but
        # write ONLY the pending operation's before-images. Earlier commits
        # are evidence, never rollback targets.
        for operation in reversed(operations):
            commit = operation['commit']
            if commit is not None and sha(virtual) != commit['imageSHA256']:
                raise ValueError('历史提交摘要不一致')
            virtual, planned = plan_rollback(virtual, operation['header'], operation['writes'])
            if operation is pending:
                target, ranges = virtual, planned
        if sha(virtual) != events[0]['originalSHA256']:
            raise ValueError('会话起点摘要不一致')
        commits = sum(op['commit'] is not None for op in operations)
        if terminal:
            if sha(current) != terminal['imageSHA256']:
                raise ValueError('恢复结束后的镜像发生修改')
            return {'state': 'rolled-back', 'writes': 0, 'commits': commits}
        if pending is None:
            return {'state': 'committed', 'writes': 0, 'commits': commits}
        if read_image(fd) != current:
            raise ValueError('恢复规划期间镜像发生修改')
        writes = 0
        for start, end in ranges:
            at = start
            while at < end:
                count = os.pwrite(fd, target[at:end], at)
                if count <= 0:
                    raise OSError('恢复短写')
                at += count
            os.fsync(fd)
            writes += 1
            if after_write:
                after_write(writes)
        expected = pending['header']['originalSHA256']
        if sha(read_image(fd)) != expected:
            raise ValueError('恢复检查点不一致')
        append(log, {'kind': 'recovered', 'operation': pending['header']['operation'],
                     'imageSHA256': expected, 'sequence': len(events), 'previous': previous})
        return {'state': 'rolled-back', 'writes': writes, 'commits': commits}
    finally:
        if log is not None:
            os.close(log)
        os.close(fd)
