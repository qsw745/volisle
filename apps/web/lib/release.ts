/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.8.0',
  build: 66,
  date: '2026 年 10 月 6 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 6, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.8.0-arm64.dmg',
  dmgSize: '4.9 MB',
  dmgSha256: 'ab71841e57ea007534252dd1b5aea886e3b44fd5577e0f7d5852d9aeaedd6692',
  source: '/downloads/Volisle-0.8.0-source.tar.gz',
  sourceSize: '19.7 MB',
  sourceSha256: '7dc1031e71be133d183e029053aa918591ce5de8fb787c942bb1b99484707edd',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
