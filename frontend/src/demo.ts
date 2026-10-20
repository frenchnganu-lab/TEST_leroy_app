import type { Cabinet } from "./types";
// Fictional demonstration; never shown as real designer data.
export const demo: Cabinet = {
  designer: {
    designer_id: "DEMO",
    full_name: "Александра Миронова",
    level_code: "bronze",
  },
  balance: { commission_rub: 1500, bonus_lr: 45000 },
  rub_per_lr: 0.2,
  loyalty: {
    weight: 320,
    next_level: "silver",
    next_threshold: 500,
    period: "Август — декабрь 2026",
  },
  project_summary: {
    active: 2,
    delivered: 1,
    total: 3,
    total_amount_rub: 890000,
  },
  projects: [
    {
      order_number: "DEMO-003",
      amount_rub: 580000,
      status: "in_progress",
      delivered_at: null,
    },
    {
      order_number: "DEMO-002",
      amount_rub: 260000,
      status: "in_progress",
      delivered_at: null,
    },
    {
      order_number: "DEMO-001",
      amount_rub: 50000,
      status: "delivered",
      delivered_at: "2026-10-17T12:00:00+07:00",
    },
  ],
  operations: [
    {
      operation_type: "event_bonus",
      currency: "LR",
      amount: 10000,
      event_at: "2026-10-19T12:00:00+07:00",
    },
    {
      operation_type: "mention_bonus",
      currency: "LR",
      amount: 10000,
      event_at: "2026-10-18T12:00:00+07:00",
    },
    {
      operation_type: "project_bonus",
      currency: "LR",
      amount: 25000,
      event_at: "2026-10-17T12:00:00+07:00",
      order_number: "DEMO-001",
    },
    {
      operation_type: "project_share",
      currency: "RUB",
      amount: 1500,
      event_at: "2026-10-17T12:00:00+07:00",
      order_number: "DEMO-001",
    },
  ],
  referral_count: 2,
  test_mode: true,
};
