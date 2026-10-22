/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.7',
  build: 79,
  date: '2026 年 10 月 22 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 22, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.7-universal.dmg',
  dmgSize: '12.7 MB',
  dmgSha256: '8c7a37ae40feacadaed7b671d34d59c8f83ce3905578deab255f78583d504701',
  source: '/downloads/Volisle-0.9.7-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: 'cc730de265effbe4eb09b70bd4376c11dc6c7435158f10a81f7007d87d4e3b92',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
