/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.5',
  build: 77,
  date: '2026 年 10 月 19 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 19, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.5-universal.dmg',
  dmgSize: '12.7 MB',
  dmgSha256: '042ce5933d302588ed463ad6d232a9d02e3bf4b1c9b230e51a39340b9627737f',
  source: '/downloads/Volisle-0.9.5-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: 'a56f88aaf9bf8bd9c534c019f2c038babc18d41b6cca3e17c9069d59702a2e24',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
