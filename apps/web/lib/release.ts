/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.9',
  build: 81,
  date: '2026 年 10 月 26 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 26, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.9-universal.dmg',
  dmgSize: '12.7 MB',
  dmgSha256: '51b1487c96be4f1d420e681fcdc6f6244e991ee471e0014eb7f398b6dc20afc1',
  source: '/downloads/Volisle-0.9.9-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: 'b4a9caf20a4f120d1ef7f6491dd4cb083a8f571148ef7d68cd4b87a6361e718d',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
