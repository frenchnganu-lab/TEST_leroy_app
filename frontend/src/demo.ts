import type { Cabinet } from './types';
// Entirely fictional sample. Not a mirror of the designers spreadsheet.
export const demo: Cabinet = {
  designer: { designer_id: 'DEMO', full_name: 'Александра — демо', level_code: 'bronze' },
  balance: { commission_rub: 1500, bonus_lr: 45000 },
  projects: [{ order_number: 'DEMO-001', amount_rub: 50000, status: 'delivered' }],
  operations: [
    { operation_type: 'event_bonus', currency: 'LR', amount: 10000, event_at: '2026-10-19T12:00:00+07:00' },
    { operation_type: 'mention_bonus', currency: 'LR', amount: 10000, event_at: '2026-10-18T12:00:00+07:00' },
    { operation_type: 'project_bonus', currency: 'LR', amount: 25000, event_at: '2026-10-17T12:00:00+07:00' },
    { operation_type: 'project_share', currency: 'RUB', amount: 1500, event_at: '2026-10-17T12:00:00+07:00' }
  ], referral_count: 2, test_mode: true
};
