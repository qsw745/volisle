/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.4',
  build: 76,
  date: '2026 年 10 月 12 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 12, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.4-universal.dmg',
  dmgSize: '12.6 MB',
  dmgSha256: 'c05ddb85e804cb0816597cc6f65ac9c84152108f5a591d3f341aecea94d65646',
  source: '/downloads/Volisle-0.9.4-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: 'd0560e8ef6b114622b193469bd1c4eaf50498c4905bc1add993c5775891789e2',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
