import type { CSSProperties } from 'react';
export type IconName = 'disk' | 'folder' | 'shield' | 'eject' | 'arrow' | 'check' | 'menu' | 'close' | 'sun' | 'moon' | 'state' | 'write';
const paths: Record<IconName, React.ReactNode> = {
  disk: <><path d="M5 3h14l2 13v5H3v-5L5 3Z"/><path d="M3 16h18M6 18.5h.01M9 18.5h.01"/></>,
  folder: <path d="M3 6h6l2 2h10v12H3V6Z"/>,
  shield: <><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/></>,
  eject: <><path d="m12 4 9 11H3L12 4Z"/><path d="M3 20h18"/></>,
  arrow: <path d="M5 12h14m-5-5 5 5-5 5"/>,
  check: <path d="m5 12 4 4L19 6"/>,
  menu: <path d="M4 7h16M4 12h16M4 17h16"/>,
  close: <path d="m6 6 12 12M6 18 18 6"/>,
  sun: <><circle cx="12" cy="12" r="4"/><path d="M12 1v2m0 18v2M1 12h2m18 0h2M4 4l2 2m12 12 2 2M4 20l2-2M18 6l2-2"/></>,
  moon: <path d="M21 13A9 9 0 0 1 11 3a9 9 0 1 0 10 10Z"/>,
  state: <><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h3"/></>,
  write: <><path d="m4 16 12-12 4 4L8 20H4v-4Z"/><path d="m13 7 4 4"/></>,
};
export function Icon({ name, size = 22, style }: { name: IconName; size?: number; style?: CSSProperties }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={style}>{paths[name]}</svg>;
}
