'use client';

import { useState } from 'react';
import type { Locale } from '@/lib/i18n';

const install = 'brew install qsw745/volisle/volisle';
const upgrade = 'brew upgrade -g volisle';

const copy = {
  zh: {
    title: '使用 Homebrew 安装',
    setup: '已安装 Homebrew？在终端运行以下命令，安装后按盘屿提示完成首次设置。',
    update: '通过 Homebrew 更新',
    updateNote: '日常可在盘屿里选择“检查更新”。如果是通过 Homebrew 安装的，先推出盘屿挂载的磁盘，再运行：',
    refresh: '如果没有找到新版，先运行',
    period: '。',
    installLabel: '复制安装命令', updateLabel: '复制更新命令',
    button: '复制', copied: '已复制', failed: '无法自动复制，请手动选择命令。',
  },
  en: {
    title: 'Install with Homebrew',
    setup: 'Already have Homebrew? Run this in Terminal, then follow the setup prompts in Volisle.',
    update: 'Update with Homebrew',
    updateNote: 'For regular updates, choose Check for Updates in Volisle. If you installed with Homebrew, eject the disks mounted by Volisle before running:',
    refresh: 'If the new version does not appear, run',
    period: ' first.',
    installLabel: 'Copy install command', updateLabel: 'Copy update command',
    button: 'Copy', copied: 'Copied', failed: 'Automatic copying is unavailable. Select and copy the command manually.',
  },
};

function CopyCommand({ command, label, c }: { command: string; label: string; c: typeof copy.zh }) {
  const [status, setStatus] = useState('');

  async function copyToClipboard() {
    try {
      await navigator.clipboard.writeText(command);
      setStatus(c.copied);
    } catch {
      setStatus(c.failed);
    }
  }

  return <>
    <div className="brew-command">
      <code>{command}</code>
      <button type="button" aria-label={label} onClick={copyToClipboard}>{c.button}</button>
    </div>
    <span className="brew-status" role="status">{status}</span>
  </>;
}

export function HomebrewInstall({ locale }: { locale: Locale }) {
  const c = copy[locale];
  return <details className="brew-install">
    <summary>{c.title}</summary>
    <p>{c.setup}</p>
    <CopyCommand command={install} label={c.installLabel} c={c}/>
    <h3>{c.update}</h3>
    <p>{c.updateNote}</p>
    <CopyCommand command={upgrade} label={c.updateLabel} c={c}/>
    <p>{c.refresh} <code>brew update</code>{c.period}</p>
  </details>;
}
