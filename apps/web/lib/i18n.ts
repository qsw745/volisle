import type { Metadata } from 'next';

export type Locale = 'zh' | 'en';

/** A site path such as `/help/` in the given language (`/en/help/` for English). */
export function localePath(locale: Locale, path: string): string {
  return locale === 'en' ? `/en${path}` : path;
}

/** The same page in the other language, from a path without the base path. */
export function counterpartPath(pathname: string): { locale: Locale; path: string } {
  if (pathname === '/en' || pathname.startsWith('/en/')) return { locale: 'zh', path: pathname.slice(3) || '/' };
  return { locale: 'en', path: `/en${pathname}` };
}

const SITE = 'https://qisw.top/volisle';

/** Absolute URL: relative metadata URLs are ambiguous (`./` resolves against the page). */
function absolute(path: string): string {
  return SITE + path;
}

/** Canonical URL plus hreflang links between the Chinese and English versions of a page. */
export function alternates(locale: Locale, path: string): Metadata['alternates'] {
  return {
    canonical: absolute(localePath(locale, path)),
    languages: { 'zh-CN': absolute(path), en: absolute(localePath('en', path)), 'x-default': absolute(path) },
  };
}

export const ui = {
  zh: {
    htmlLang: 'zh-CN',
    brandHome: '盘屿 Volisle 首页',
    skip: '跳转到主要内容',
    mainNav: '主导航',
    features: '功能',
    compatibility: '兼容性',
    help: '帮助',
    download: '下载',
    openNav: '打开导航',
    closeNav: '关闭导航',
    switchLabel: 'English',
    switchTitle: 'Read this page in English',
    tagline: '让硬盘，在 Mac 上自在读写。',
    footerNav: '页脚导航',
    privacy: '隐私',
    terms: '许可',
    changelog: '更新日志',
    support: '支持盘屿',
    footerNote: '免费开源的 Mac NTFS 磁盘助手。',
    back: '← 返回盘屿',
    tableCaption: '盘屿当前兼容性及验证范围',
    tableItem: '环境与功能',
    tableState: '当前状态',
    tableScope: '验证范围',
  },
  en: {
    htmlLang: 'en',
    brandHome: 'Volisle home',
    skip: 'Skip to main content',
    mainNav: 'Main navigation',
    features: 'Features',
    compatibility: 'Compatibility',
    help: 'Help',
    download: 'Download',
    openNav: 'Open navigation',
    closeNav: 'Close navigation',
    switchLabel: '中文',
    switchTitle: '阅读本页中文版',
    tagline: 'Your drives, read-write on Mac.',
    footerNav: 'Footer navigation',
    privacy: 'Privacy',
    terms: 'License',
    changelog: 'Release Notes',
    support: 'Support Volisle',
    footerNote: 'A free, open-source NTFS helper for Mac.',
    back: '← Back to Volisle',
    tableCaption: 'Volisle’s current compatibility and what has been verified',
    tableItem: 'Environment or feature',
    tableState: 'Status',
    tableScope: 'What was verified',
  },
} as const satisfies Record<Locale, Record<string, string>>;
