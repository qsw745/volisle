import { compatibility } from '@/lib/content';
import { ui, type Locale } from '@/lib/i18n';
export function CompatibilityTable({ locale = 'zh' }: { locale?: Locale }) {
  const t = ui[locale];
  return <div className="table-wrap"><table><caption className="sr-only">{t.tableCaption}</caption><thead><tr><th scope="col">{t.tableItem}</th><th scope="col">{t.tableState}</th><th scope="col">{t.tableScope}</th></tr></thead><tbody>{compatibility[locale].map(row => <tr key={row.item}><th scope="row">{row.item}</th><td><span className={`status ${row.limited ? 'unsupported' : ''}`}>{row.state}</span></td><td>{row.detail}</td></tr>)}</tbody></table></div>;
}
