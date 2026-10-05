import type { Metadata } from 'next';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { ui } from '@/lib/i18n';
import '../globals.css';
export const metadata: Metadata = {
  title: { default: '盘屿 Volisle — 免费开源的 Mac NTFS 磁盘助手', template: '%s · 盘屿 Volisle' },
  description: '插上 NTFS 硬盘或 U 盘，在 Mac 上直接读写。自动检查、异常断开自动恢复、保留 Windows 权限。免费开源。',
  metadataBase: new URL('https://qisw.top/volisle/'),
  openGraph: { type: 'website', locale: 'zh_CN', alternateLocale: ['en_US'], siteName: '盘屿 Volisle', url: 'https://qisw.top/volisle/', images: [{ url: 'screenshots/app-light.webp', width: 1680, height: 1080, alt: '盘屿截图' }] },
};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang={ui.zh.htmlLang}><body><a className="skip-link" href="#main">{ui.zh.skip}</a><Header locale="zh"/>{children}<Footer locale="zh"/></body></html>;
}
