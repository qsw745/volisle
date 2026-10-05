import type { NextConfig } from 'next';
const config: NextConfig = { output: 'export', basePath: process.env.NEXT_PUBLIC_BASE_PATH || '', trailingSlash: true, images: { unoptimized: true }, poweredByHeader: false,
  // Two root layouts (Chinese and /en/) need a 404 page outside both.
  experimental: { globalNotFound: true } };
export default config;
