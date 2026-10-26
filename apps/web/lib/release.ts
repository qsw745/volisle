/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.8',
  build: 80,
  date: '2026 年 10 月 22 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 22, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.8-universal.dmg',
  dmgSize: '12.7 MB',
  dmgSha256: '1502171daf22149de1685ee9b00e80385746e30afee12795f6450f48d925c8be',
  source: '/downloads/Volisle-0.9.8-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: '2d9d27aba218a8dae4e4f8ee98f25b32d1741247b2dd38cb3df95bff3024b47a',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
