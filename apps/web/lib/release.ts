/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.3',
  build: 75,
  date: '2026 年 10 月 11 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 11, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.3-universal.dmg',
  dmgSize: '12.4 MB',
  dmgSha256: 'ab0e8704cf8ef04a51f09faa1c2a01b7e61cd7b3bcaaf06cbba103c124dea0cd',
  source: '/downloads/Volisle-0.9.3-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: 'e8bb5a8b67ae43d60c76fd4ed24136a1a2621bca4e31b21727779d726951666b',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
