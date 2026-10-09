import type { IconName } from '@/components/Icon';
import type { Locale } from './i18n';
import { release } from './release';

type Block = { eyebrow: string; title: [string, string]; text: string };

export type HomeCopy = {
  cta: string;
  heroEyebrow: string;
  heroTitle: [string, string];
  heroText: string;
  learnMore: string;
  releaseNote: string;
  featuresLabel: string;
  features: { icon: IconName; title: string; text: string }[];
  steps: Block & { items: [string, string][] };
  native: Block & { tags: string[]; imageAlt: string; image: string };
  privacy: Block & { link: string; pointTitle: string; pointText: string };
  compat: Block & { link: string };
  faqTitle: string;
  faqEyebrow: string;
  download: Block & { caption: string };
};

const published = release.published;

export const homeCopy: Record<Locale, HomeCopy> = {
  zh: {
    cta: published ? '免费下载' : '了解发布进度',
    heroEyebrow: '盘屿 · Mac 上的 NTFS 读写',
    heroTitle: ['让硬盘，', '在 Mac 上自在读写。'],
    heroText: '插上 Windows 格式的硬盘，就像普通磁盘一样在 Finder 里编辑和保存。',
    learnMore: '了解功能',
    releaseNote: published ? `版本 ${release.version} · 免费开源 · Apple 芯片（Intel 测试版） · ${release.minimumSystem} 或更高` : `${release.version} 即将发布 · 免费开源`,
    featuresLabel: '核心功能',
    features: [
      { icon: 'write', title: '插上就能写', text: '首次设置后，插入 NTFS 硬盘或 U 盘，自动检查并开启读写。' },
      { icon: 'folder', title: '依然是 Finder', text: '在 Finder 和常用应用里新建、编辑、保存，和普通磁盘一样。' },
      { icon: 'shield', title: '意外断开有保护', text: '每次写入都有记录。直接拔线后，下次连接会先恢复再开启读写；拔线时正在拷贝的文件请重新拷贝。' },
      { icon: 'state', title: '与 Windows 互通', text: '保留 Windows 文件权限。Windows 没有安全弹出时，先保持只读并告诉你原因。' },
    ],
    steps: {
      eyebrow: '为简单而设计', title: ['连接硬盘，', '自在使用。'], text: '第一次设置之后，就只剩插上和推出。',
      items: [['一次设置', '安装后按提示启用文件系统扩展和后台组件，之后不用再管。'], ['插入磁盘', '盘屿在后台检查磁盘，通过后自动开启读写，关闭窗口也照常工作。'], ['照常使用', '在 Finder 和应用里操作文件，用完点“推出”再拔线。']],
    },
    native: {
      eyebrow: '原生，恰到好处', title: ['熟悉的 Mac，', '熟悉的方式。'], text: '原生侧边栏、菜单栏入口、深浅色外观、键盘快捷键。\n少一点打扰，多一点专注。',
      tags: ['SwiftUI 原生界面', '本地运行', '无需账号'], image: 'app-dark.webp', imageAlt: '盘屿深色外观截图：一块 2 TB NTFS 硬盘处于可读写状态',
    },
    privacy: {
      eyebrow: '你的文件，你来掌握', title: ['文件留在硬盘。', '控制留在你手中。'], text: '核心功能在本地运行，不上传文件内容。\n没有账号、统计或遥测，诊断只由你主动导出。',
      link: '了解隐私设计', pointTitle: '有疑问，就先停下来。', pointText: 'Windows 休眠、没有安全弹出或磁盘需要检查时，保持只读并说明原因；不自动修复，也不强制推出。',
    },
    compat: { eyebrow: '兼容性，一目了然', title: ['验证到哪里，', '就写到哪里。'], text: '没有实机验证的环境，不写成支持。\n还没覆盖的，也在这里标明。', link: '查看完整兼容性说明' },
    faqEyebrow: '常见问题',
    faqTitle: '你可能还想了解。',
    download: {
      eyebrow: '免费，开源', title: ['让硬盘，', '自在读写。'],
      text: published ? `盘屿 ${release.version} · 需要 ${release.minimumSystem} 或更高版本；Apple 芯片 Mac 正式支持，Intel Mac 为测试版。` : `盘屿 ${release.version} 正在做最后的验证，完成后在这里提供下载。`,
      caption: '没有账号，没有订阅，源码开放。',
    },
  },
  en: {
    cta: published ? 'Download Free' : 'Release Status',
    heroEyebrow: 'Volisle · NTFS read-write for Mac',
    heroTitle: ['Your drives,', 'read-write on Mac.'],
    heroText: 'Connect a Windows-formatted drive and edit and save in Finder, just like any other disk.',
    learnMore: 'Explore features',
    releaseNote: published ? `Version ${release.version} · Free and open source · Apple silicon (Intel beta) · ${release.minimumSystem} or later` : `${release.version} coming soon · Free and open source`,
    featuresLabel: 'Key features',
    features: [
      { icon: 'write', title: 'Plug in and write', text: 'After a one-time setup, connect an NTFS drive or flash drive and it’s checked and made writable automatically.' },
      { icon: 'folder', title: 'Still just Finder', text: 'Create, edit, and save in Finder and the apps you already use, just like any other disk.' },
      { icon: 'shield', title: 'Protected when unplugged', text: 'Every write is recorded. Unplug by accident and Volisle recovers the disk before turning on writing again; copy any file that was in progress once more.' },
      { icon: 'state', title: 'Works with Windows', text: 'Windows file permissions are preserved. If Windows didn’t eject the disk safely, it stays read-only and Volisle tells you why.' },
    ],
    steps: {
      eyebrow: 'Designed to be simple', title: ['Plug in.', 'Get going.'], text: 'After the first setup, all that’s left is plugging in and ejecting.',
      items: [['Set up once', 'After installing, follow the prompts to turn on the file system extension and background component. Then forget about it.'], ['Connect a disk', 'Volisle checks the disk in the background and turns on write access when it passes—even with the window closed.'], ['Use it as usual', 'Work with files in Finder and your apps, then click “Eject” before unplugging.']],
    },
    native: {
      eyebrow: 'Native, and just enough', title: ['A familiar Mac.', 'The familiar way.'], text: 'A native sidebar, a menu bar item, light and dark appearances, and keyboard shortcuts.\nFewer interruptions, more focus.',
      tags: ['Native SwiftUI', 'Runs locally', 'No account'], image: 'app-dark-en.webp', imageAlt: 'Volisle in Dark Mode: a 2 TB NTFS drive with write access on',
    },
    privacy: {
      eyebrow: 'Your files, your control', title: ['Files stay on your drive.', 'Control stays with you.'], text: 'Everything important runs on your Mac and file contents are never uploaded.\nNo accounts, analytics, or telemetry—diagnostics are exported only when you choose.',
      link: 'How privacy works', pointTitle: 'When in doubt, it stops.', pointText: 'If Windows is hibernated, didn’t eject safely, or the disk needs a check, Volisle keeps it read-only and explains why. It never repairs or force-ejects on its own.',
    },
    compat: { eyebrow: 'Compatibility at a glance', title: ['Verified means', 'actually verified.'], text: 'Anything not tested on real hardware isn’t called supported.\nWhat isn’t covered yet is listed here too.', link: 'See full compatibility details' },
    faqEyebrow: 'FAQ',
    faqTitle: 'You might also want to know.',
    download: {
      eyebrow: 'Free and open source', title: ['Your drives,', 'read-write.'],
      text: published ? `Volisle ${release.version} · Requires ${release.minimumSystem} or later; Macs with Apple silicon are supported, Intel-based Macs as a beta.` : `Volisle ${release.version} is in final testing and will be available here soon.`,
      caption: 'No account. No subscription. Open source.',
    },
  },
};
