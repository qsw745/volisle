'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import { Icon } from './Icon';
import { BrandMark } from './BrandMark';
import { counterpartPath, localePath, ui, type Locale } from '@/lib/i18n';
export function Header({ locale }: { locale: Locale }) {
  const [open, setOpen] = useState(false);
  const t = ui[locale];
  const other = counterpartPath(usePathname() || localePath(locale, '/'));
  const close = () => setOpen(false);
  return <header className="site-header"><div className="nav-wrap">
    <Link href={localePath(locale, '/')} className="brand" aria-label={t.brandHome} onClick={close}><span className="brand-symbol"><BrandMark/></span>{locale === 'zh' ? <>盘屿 <span>Volisle</span></> : 'Volisle'}</Link>
    <nav aria-label={t.mainNav} className={open ? 'nav-links is-open' : 'nav-links'} id="main-nav">
      <Link href={localePath(locale, '/#features')} onClick={close}>{t.features}</Link><Link href={localePath(locale, '/compatibility/')} onClick={close}>{t.compatibility}</Link><Link href={localePath(locale, '/help/')} onClick={close}>{t.help}</Link>
      <Link className="language-switch" href={other.path} hrefLang={ui[other.locale].htmlLang} lang={ui[other.locale].htmlLang} title={t.switchTitle} onClick={close}>{t.switchLabel}</Link>
    </nav>
    <Link className="nav-cta" href={localePath(locale, '/download/')} onClick={close}>{t.download}</Link>
    <button className="menu-toggle" onClick={() => setOpen(!open)} aria-expanded={open} aria-controls="main-nav" aria-label={open ? t.closeNav : t.openNav}><Icon name={open ? 'close' : 'menu'}/></button>
  </div></header>;
}
