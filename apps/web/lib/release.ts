/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.6.1',
  build: 64,
  date: '2026 年 10 月 5 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 5, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.6.1-arm64.dmg',
  dmgSize: '4.2 MB',
  dmgSha256: 'e50a792891efd6262f6702cd703fb57296ab854d07a9f8ce5f154d8a1fa21999',
  source: '/downloads/Volisle-0.6.1-source.tar.gz',
  sourceSize: '19.6 MB',
  sourceSha256: '812a2b12408a107fc4c0053c2caad366a960d5777a4b2a6d3723a0b6e8889947',
  minimumSystem: 'macOS 26.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
