/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.0',
  build: 72,
  date: '2026 年 10 月 9 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 9, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.0-universal.dmg',
  dmgSize: '11.9 MB',
  dmgSha256: 'a65c69adab65a9138767a5f3c56fb7502cb878938202da4526acc3c8994eba83',
  source: '/downloads/Volisle-0.9.0-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: '5f53226a6a3603245695e6b829fda2b704fc27e33027ddc68f688b98ef1eee14',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
