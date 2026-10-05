import type { Metadata } from 'next';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { ui } from '@/lib/i18n';
import '../globals.css';
export const metadata: Metadata = {
  title: { default: 'Volisle — Free, Open-Source NTFS for Mac', template: '%s · Volisle' },
  description: 'Connect an NTFS drive or USB flash drive and read and write it on your Mac. Automatic checks, automatic recovery after unexpected disconnects, and Windows permissions preserved. Free and open source.',
  metadataBase: new URL('https://qisw.top/volisle/'),
  openGraph: { type: 'website', locale: 'en_US', alternateLocale: ['zh_CN'], siteName: 'Volisle', url: 'https://qisw.top/volisle/en/', images: [{ url: 'screenshots/app-light-en.webp', width: 1680, height: 1080, alt: 'Volisle screenshot' }] },
};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang={ui.en.htmlLang}><body><a className="skip-link" href="#main">{ui.en.skip}</a><Header locale="en"/>{children}<Footer locale="en"/></body></html>;
}
