export type Cabinet = {
  designer: { designer_id: string; full_name: string; level_code: string };
  balance: { commission_rub: number; bonus_lr: number };
  projects: { order_number: string; amount_rub: number; status: string }[];
  operations: { operation_type: string; currency: string; amount: number; event_at: string }[];
  referral_count: number; test_mode: boolean;
};
declare global {
  interface Window { Telegram?: { WebApp: { initData: string; ready(): void; expand(): void } } }
}
