/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.8.3',
  build: 70,
  date: '2026 年 10 月 8 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 8, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.8.3-arm64.dmg',
  dmgSize: '6.2 MB',
  dmgSha256: 'eacd9b95ab29a9360d70b39d2a0f35853cdf4b4fe6ee7c0d0c874e5526832faf',
  source: '/downloads/Volisle-0.8.3-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: 'd2ad04da1e1948fba13614081de4ac8ae8e69b7fd484f49abd2311e08e8a72de',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
