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
};
export type Cabinet = {
  designer: { designer_id: string; full_name: string; level_code: string };
  balance: { commission_rub: number; bonus_lr: number };
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
