import Link from 'next/link';
import { BrandMark } from './BrandMark';
import { localePath, ui, type Locale } from '@/lib/i18n';
export function Footer({ locale }: { locale: Locale }) {
  const t = ui[locale];
  const to = (path: string) => localePath(locale, path);
  const name = locale === 'zh' ? <>盘屿 <span>Volisle</span></> : 'Volisle';
  return <footer className="site-footer"><div className="container footer-top"><Link className="brand" href={to('/')} aria-label={t.brandHome}><span className="brand-symbol"><BrandMark/></span>{name}</Link><p>{t.tagline}</p><nav aria-label={t.footerNav}><Link href={to('/privacy/')}>{t.privacy}</Link><Link href={to('/terms/')}>{t.terms}</Link><Link href={to('/changelog/')}>{t.changelog}</Link><Link href={to('/help/')}>{t.help}</Link><Link href={to('/support/')}>{t.support}</Link></nav></div><div className="container footer-bottom"><span>© 2026 {locale === 'zh' ? '盘屿 Volisle' : 'Volisle'} · GNU GPL v2</span><span>{t.footerNote}</span></div></footer>;
}
