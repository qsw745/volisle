/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.11',
  build: 93,
  date: '2026 年 11 月 10 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'November 10, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.11-universal.dmg',
  dmgSize: '13.4 MB',
  dmgSha256: '239e9de9f96ed0f1e9809ee8683632502864f10956b505b40bb9f41b785d8850',
  source: '/downloads/Volisle-0.9.11-source.tar.gz',
  sourceSize: '20.5 MB',
  sourceSha256: 'd44671196eb77b6b8287eec4a004015b7044487af94da36e6e388c7f613c6cf4',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
