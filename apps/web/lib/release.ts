/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.10',
  build: 85,
  date: '2026 年 10 月 27 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 27, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.10-universal.dmg',
  dmgSize: '12.9 MB',
  dmgSha256: '265404d551121899827040bc73cabb43824d79cc70be856103e93cabc9f740b6',
  source: '/downloads/Volisle-0.9.10-source.tar.gz',
  sourceSize: '20.4 MB',
  sourceSha256: 'f8c240da867a2fb693e6abc45f5d9dea877ace172868963f6fbf821858defc16',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
