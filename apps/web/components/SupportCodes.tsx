import Image from 'next/image';
const base = process.env.NEXT_PUBLIC_BASE_PATH || '';
/** The owner's WeChat reward (赞赏) code. */
export function SupportCodes({ locale = 'zh' }: { locale?: 'zh' | 'en' }) {
  const zh = locale === 'zh';
  return <figure className="support-code"><Image src={`${base}/support/wechat-reward.jpg`} width={600} height={594} loading="lazy" alt={zh ? '微信赞赏码' : 'WeChat reward code'}/><figcaption>{zh ? '微信扫一扫，金额随意' : 'Scan with WeChat. Any amount.'}</figcaption></figure>;
}
