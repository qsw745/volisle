import Link from 'next/link';
import Image from 'next/image';
import { ArticlePage } from './ArticlePage';
import { Icon } from './Icon';
import { release } from '@/lib/release';
import { history } from '@/lib/history';
import { localePath, type Locale } from '@/lib/i18n';
const base = process.env.NEXT_PUBLIC_BASE_PATH || '';
/** 0.5.7 and earlier: unplugging could leave stale data (fixed in 0.5.5), and a quick eject could roll back new files on Windows 11 disks (fixed in 0.5.8). */
const hasDataRisk = (version: string) => { const [a, b, c] = version.split('.').map(Number); return a * 1e6 + b * 1e3 + c <= 5007; };
const copy = {
  zh: {
    title: '免费下载盘屿。', lead: '官网版免费，源码以 GNU GPL v2 开放。没有账号，也没有内购。', iconAlt: '盘屿应用图标', name: '盘屿',
    meta: `${release.date} · ${release.dmgSize} · Apple 芯片 · ${release.minimumSystem} 或更高`, pending: '正在做最后的验证，完成后在这里提供下载。',
    button: '下载 .dmg', stepsTitle: '三步开始使用',
    steps: [['打开安装包', '双击下载的 .dmg，把“盘屿”拖到“应用程序”文件夹。'], ['完成首次设置', '从“应用程序”打开盘屿，按窗口顶部的提示启用文件系统扩展、允许后台组件，并开启完全磁盘访问。'], ['插入磁盘', '插入 NTFS 硬盘或 U 盘，检查通过后自动开启读写。']],
    notarized: '安装包已通过 Apple 公证。之后盘屿会自动检查更新，安装前先安全结束磁盘读写。', notice: '完成最后的验证之前，这里不提供安装包。',
    reqTitle: '系统要求', req1: 'Apple 芯片 Mac（不支持 Intel）。', req2a: `${release.minimumSystem} 或更高版本。完整验证在 macOS 27.2 上完成，详见`, req2link: '兼容性', req2b: '。', req3: '外接 USB NTFS 硬盘或 U 盘。',
    sumsTitle: '校验与源码', sumsA: '以上为 SHA-256。在“终端”中运行 ', sumsCode: 'shasum -a 256 文件名', sumsB: ' 即可核对。源码包含构建脚本和第三方许可声明，可离线重新构建。',
    changelog: '更新日志 ›', help: '使用帮助 ›',
    historyTitle: '历史版本', historyLead: '旧版本里的已知问题都在后续版本中修复了（见更新日志），只建议在需要退回旧版时使用；打开后盘屿会提示更新到最新版本。标有“有数据风险”的版本存在已知的数据问题（见更新日志 0.5.5 与 0.5.8），请不要用它们读写重要数据。', historyRisk: '有数据风险',
    historyDmg: '安装包', historySource: '源码', historySums: 'SHA-256',
  },
  en: {
    title: 'Download Volisle for free.', lead: 'The website version is free, with source code under the GNU GPL v2. No account, no in-app purchases.', iconAlt: 'Volisle app icon', name: 'Volisle',
    meta: `${release.dateEn} · ${release.dmgSize} · Apple silicon · ${release.minimumSystem} or later`, pending: 'Volisle is in final testing and will be available here soon.',
    button: 'Download .dmg', stepsTitle: 'Get started in three steps',
    steps: [['Open the installer', 'Double-click the downloaded .dmg and drag Volisle to the Applications folder.'], ['Finish setup', 'Open Volisle from Applications and follow the prompt at the top of the window to turn on the file system extension, allow the background component, and turn on Full Disk Access.'], ['Connect a disk', 'Connect an NTFS drive or USB flash drive. Write access turns on automatically once the check passes.']],
    notarized: 'The installer is notarized by Apple. Volisle checks for updates automatically and safely ends disk writes before installing one.', notice: 'The installer will be available here once final testing is complete.',
    reqTitle: 'System requirements', req1: 'A Mac with Apple silicon (Intel isn’t supported).', req2a: `${release.minimumSystem} or later. Full verification was done on macOS 27.2; see `, req2link: 'Compatibility', req2b: ' for details.', req3: 'An external USB NTFS drive or flash drive.',
    sumsTitle: 'Checksums and source code', sumsA: 'These are SHA-256 checksums. To verify, run ', sumsCode: 'shasum -a 256 filename', sumsB: ' in Terminal. The source includes build scripts and third-party license notices, and can be rebuilt offline.',
    changelog: 'Release Notes ›', help: 'Help ›',
    historyTitle: 'Earlier versions', historyLead: 'Known issues in earlier versions are fixed in later ones (see the Release Notes). Use one only if you need to go back; Volisle will offer to update to the latest version. Versions marked “Known data risk” have known data problems (see 0.5.5 and 0.5.8 in the Release Notes); don’t use them with important data.', historyRisk: 'Known data risk',
    historyDmg: 'Installer', historySource: 'Source', historySums: 'SHA-256',
  },
};
export function DownloadPage({ locale }: { locale: Locale }) {
  const c = copy[locale];
  const to = (path: string) => localePath(locale, path);
  return <ArticlePage title={c.title} lead={c.lead} locale={locale}>
  <div className="release-panel"><Image className="release-app-icon" src={`${base}/brand/app-icon.svg`} width={80} height={80} alt={c.iconAlt}/><div className="release-meta">
    <h2>{c.name} {release.version}</h2>
    <p>{release.published ? c.meta : c.pending}</p>
  </div>{release.published && <a className="button primary release-button" href={`${base}${release.dmg}`} download>{c.button} <Icon name="arrow" size={17}/></a>}</div>
  {release.published ? <>
    <h2>{c.stepsTitle}</h2>
    <ol className="install-steps">{c.steps.map(([title, text], i) => <li key={title}><span className="step-number">0{i + 1}</span><h3>{title}</h3><p>{text}</p></li>)}</ol>
    <p>{c.notarized}</p>
  </> : <p className="notice">{c.notice}</p>}
  <h2>{c.reqTitle}</h2><ul><li>{c.req1}</li><li>{c.req2a}<Link className="inline-link" href={to('/compatibility/')}>{c.req2link}</Link>{c.req2b}</li><li>{c.req3}</li></ul>
  {release.published && <>
    <h2>{c.sumsTitle}</h2>
    <dl className="checksums">
      <dt>Volisle-{release.version}-arm64.dmg</dt><dd><code>{release.dmgSha256}</code></dd>
      <dt><a className="inline-link" href={`${base}${release.source}`}>Volisle-{release.version}-source.tar.gz</a> · {release.sourceSize}</dt><dd><code>{release.sourceSha256}</code></dd>
    </dl>
    <p>{c.sumsA}<code>{c.sumsCode}</code>{c.sumsB}</p>
    {history.length > 0 && <>
      <h2 id="history">{c.historyTitle}</h2>
      <p>{c.historyLead}</p>
      <ul className="history-list">{history.map(h => <li key={h.version}>
        <div className="history-row"><strong>{h.version}</strong><span>{locale === 'zh' ? h.date : h.dateEn}</span>{hasDataRisk(h.version) && <em className="history-risk">{c.historyRisk}</em>}
          <a className="inline-link" href={`${base}${h.dmg}`} download>{c.historyDmg} · {h.dmgSize}</a>
          <a className="inline-link" href={`${base}${h.source}`}>{c.historySource} · {h.sourceSize}</a></div>
        <details><summary>{c.historySums}</summary><dl className="checksums">
          <dt>Volisle-{h.version}-arm64.dmg</dt><dd><code>{h.dmgSha256}</code></dd>
          <dt>Volisle-{h.version}-source.tar.gz</dt><dd><code>{h.sourceSha256}</code></dd>
        </dl></details>
      </li>)}</ul>
    </>}
  </>}
  <p className="article-links"><Link className="text-link" href={to('/changelog/')}>{c.changelog}</Link><Link className="text-link" href={to('/help/')}>{c.help}</Link></p>
</ArticlePage>;
}
