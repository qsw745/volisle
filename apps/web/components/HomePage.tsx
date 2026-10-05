import { Fragment } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { AppPreview } from './AppPreview';
import { Icon } from './Icon';
import { CompatibilityTable } from './CompatibilityTable';
import { Faq } from './Faq';
import { homeCopy } from '@/lib/home-copy';
import { localePath, type Locale } from '@/lib/i18n';
const base = process.env.NEXT_PUBLIC_BASE_PATH || '';

/** Text with `\n` rendered as line breaks. */
function Lines({ text }: { text: string }) {
  return <>{text.split('\n').map((line, i) => <Fragment key={i}>{i > 0 && <br/>}{line}</Fragment>)}</>;
}
function Title({ parts }: { parts: [string, string] }) {
  return <>{parts[0]}<br/>{parts[1]}</>;
}

export function HomePage({ locale }: { locale: Locale }) {
  const c = homeCopy[locale];
  const to = (path: string) => localePath(locale, path);
  return <main id="main">
  <section className="hero"><div className="container hero-copy"><p className="hero-eyebrow">{c.heroEyebrow}</p><h1><Title parts={c.heroTitle}/></h1><p className="hero-description">{c.heroText}</p><div className="hero-actions"><Link href={to('/download/')} className="button primary">{c.cta} <Icon name="arrow" size={17}/></Link><Link href={to('/#features')} className="text-link">{c.learnMore} <span aria-hidden="true">›</span></Link></div><p className="release-note">{c.releaseNote}</p></div><AppPreview locale={locale}/></section>
  <section id="features" className="features container" aria-label={c.featuresLabel}>{c.features.map(f => <article key={f.title}><span className="feature-icon"><Icon name={f.icon} size={27}/></span><h2>{f.title}</h2><p>{f.text}</p></article>)}</section>
  <section className="steps-section"><div className="container steps-layout"><div><p className="eyebrow">{c.steps.eyebrow}</p><h2><Title parts={c.steps.title}/></h2><p className="section-note">{c.steps.text}</p></div><ol className="steps">{c.steps.items.map(([title, text], i) => <li key={title}><span className="step-number">0{i+1}</span><h3>{title}</h3><p>{text}</p></li>)}</ol></div></section>
  <section className="native-section"><div className="container native-layout"><div><p className="eyebrow">{c.native.eyebrow}</p><h2><Title parts={c.native.title}/></h2><p><Lines text={c.native.text}/></p><ul className="native-tags">{c.native.tags.map(tag => <li key={tag}>{tag}</li>)}</ul></div><figure className="native-shot"><Image src={`${base}/screenshots/${c.native.image}`} width={1680} height={1080} loading="lazy" alt={c.native.imageAlt}/></figure></div></section>
  <section className="privacy-section container"><div><p className="eyebrow">{c.privacy.eyebrow}</p><h2><Title parts={c.privacy.title}/></h2><p><Lines text={c.privacy.text}/></p><Link href={to('/privacy/')} className="text-link">{c.privacy.link} <span aria-hidden="true">›</span></Link></div><div className="privacy-points"><Icon name="shield" size={62}/><div><h3>{c.privacy.pointTitle}</h3><p>{c.privacy.pointText}</p></div></div></section>
  <section className="compat-section"><div className="container"><div className="section-heading"><div><p className="eyebrow">{c.compat.eyebrow}</p><h2><Title parts={c.compat.title}/></h2></div><p><Lines text={c.compat.text}/></p></div><CompatibilityTable locale={locale}/><Link className="text-link table-link" href={to('/compatibility/')}>{c.compat.link} <span aria-hidden="true">›</span></Link></div></section>
  <section className="faq-section container"><div><p className="eyebrow">{c.faqEyebrow}</p><h2>{c.faqTitle}</h2></div><Faq locale={locale}/></section>
  <section className="download-section"><div className="container"><p className="eyebrow">{c.download.eyebrow}</p><h2><Title parts={c.download.title}/></h2><p>{c.download.text}</p><Link className="button primary" href={to('/download/')}>{c.cta} <Icon name="arrow" size={17}/></Link><span className="download-caption">{c.download.caption}</span></div></section>
  </main>;
}
