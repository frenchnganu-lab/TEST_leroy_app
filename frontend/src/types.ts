export type Project = {
  order_number: string;
  amount_rub: number;
  status: string;
  delivered_at?: string | null;
};
export type Operation = {
  operation_type: string;
  currency: string;
  amount: number;
  event_at: string;
  order_number?: string | null;
  settled_at?: string | null;
  settled_amount?: number | null;
};
export type Cabinet = {
  designer: { designer_id: string; full_name: string; level_code: string };
  balance: {
    commission_rub: number; bonus_lr: number;
    commission_accrued_rub?: number; commission_paid_rub?: number;
    bonus_accrued_lr?: number; bonus_redeemed_lr?: number;
  };
  project_summary: {
    active: number;
    delivered: number;
    total: number;
    total_amount_rub: number;
  };
  rub_per_lr: number | null;
  loyalty: {
    weight: number;
    next_level: string;
    next_threshold: number;
    period: string;
  } | null;
  projects: Project[];
  operations: Operation[];
  referral_count: number;
  referrals?: { designer_id: string; full_name: string; created_at: string | null }[];
  referral_url?: string | null;
  test_mode: boolean;
};
declare global {
  interface Window {
    Telegram?: {
      WebApp: {
        initData: string;
        ready(): void;
        expand(): void;
        setHeaderColor?(color: string): void;
        setBackgroundColor?(color: string): void;
      };
    };
  }
}


