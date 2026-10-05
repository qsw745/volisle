import Image from 'next/image';
import { release } from '@/lib/release';
import type { Locale } from '@/lib/i18n';
const base = process.env.NEXT_PUBLIC_BASE_PATH || '';
const copy = {
  zh: { src: 'app-light.webp', alt: '盘屿截图：一块 2 TB NTFS 硬盘处于可读写状态，可打开 Finder 或推出', caption: `盘屿 ${release.version} 实际截图 · macOS 27.2` },
  en: { src: 'app-light-en.webp', alt: 'Volisle screenshot: a 2 TB NTFS drive with write access on, ready to open in Finder or eject', caption: `Volisle ${release.version} · actual screenshot · macOS 27.2` },
};
export function AppPreview({ locale = 'zh' }: { locale?: Locale }) {
  const c = copy[locale];
  return <figure className="preview-figure">
    <Image className="app-screenshot" src={`${base}/screenshots/${c.src}`} width={1680} height={1080} priority alt={c.alt}/>
    <figcaption>{c.caption}</figcaption>
  </figure>;
}
