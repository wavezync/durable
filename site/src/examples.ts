import { section } from './docs';
import type { Spec } from './sim/engine';

// Code comes from the README section named by `heading`; only the run's
// behavior (timings, what can fail, what a person can answer) lives here.
export const EXAMPLES: { slug: string; heading: string; file: string; guide?: string; spec: Spec }[] = [
  {
    slug: 'approval',
    heading: 'Approval Workflow',
    file: 'expense_approval.ex',
    guide: 'waiting',
    spec: {
      workflow: 'expense_approval',
      module: 'MyApp.ExpenseApproval',
      nodes: [
        {
          step: 'request_approval',
          as: 'decision',
          wait: {
            says: 'a manager has to approve the expense',
            actions: [
              { label: 'Approve', value: ':approved', call: '`Durable.provide_input(id, "manager", :approved)`' },
              { label: 'Reject', value: ':rejected', call: '`Durable.provide_input(id, "manager", :rejected)`' },
              { label: 'Let 3 days pass', value: ':auto_rejected', call: 'Nobody answered in 3 days, so `wait_for_approval` returned `:auto_rejected`.' },
            ],
          },
        },
        { branch: 'decision', clauses: { ':approved': [{ step: 'process', ms: 900 }], _: [{ step: 'notify_rejection', ms: 700 }] } },
      ],
    },
  },
  {
    slug: 'parallel-fetch',
    heading: 'Parallel Data Fetch',
    file: 'dashboard_builder.ex',
    guide: 'parallel',
    spec: {
      workflow: 'build_dashboard',
      module: 'MyApp.DashboardBuilder',
      nodes: [
        { step: 'init', ms: 400 },
        { parallel: [{ step: 'user', ms: 900 }, { step: 'orders', ms: 1700 }, { step: 'notifications', ms: 600 }] },
        { step: 'render', ms: 700 },
      ],
    },
  },
  {
    slug: 'trip-booking',
    heading: 'Trip Booking (Saga)',
    file: 'trip_booking.ex',
    guide: 'compensations',
    spec: {
      workflow: 'book_trip',
      module: 'MyApp.TripBooking',
      toggles: [{ label: 'Decline the card', step: 'charge' }],
      nodes: [
        { step: 'book_flight', ms: 1000, compensate: 'cancel_flight' },
        { step: 'book_hotel', ms: 900, compensate: 'cancel_hotel' },
        { step: 'charge', ms: 800, error: '`Payments.charge/2` raised: card declined' },
      ],
    },
  },
  {
    slug: 'trial-reminder',
    heading: 'Delayed & Scheduled Execution',
    file: 'trial_reminder.ex',
    guide: 'waiting',
    spec: {
      workflow: 'trial_reminder',
      module: 'MyApp.TrialReminder',
      nodes: [
        { step: 'welcome', ms: 500 },
        { step: 'wait_3_days', ms: 300, sleep: 'sleep(days(3))' },
        { step: 'check_in', ms: 500 },
        { step: 'wait_until_trial_ends', ms: 300, sleep: 'schedule_at(trial_end)' },
        { step: 'convert_or_remind', ms: 700 },
      ],
    },
  },
  {
    slug: 'payment-events',
    heading: 'Event-Driven Workflow',
    file: 'payment_flow.ex',
    guide: 'waiting',
    spec: {
      workflow: 'payment_flow',
      module: 'MyApp.PaymentFlow',
      nodes: [
        { step: 'create_invoice', ms: 700 },
        {
          step: 'await_payment',
          as: 'result',
          wait: {
            says: 'the payment provider has to send `payment.success` or `payment.failed`',
            actions: [
              { label: 'Send payment.success', value: '"payment.success"', call: 'Your webhook called `Durable.send_event(id, "payment.success", %{transaction_id: "txn_123"})`.' },
              { label: 'Send payment.failed', value: '"payment.failed"', call: 'Your webhook called `Durable.send_event(id, "payment.failed", %{})`.' },
              { label: 'Let 7 days pass', value: '"payment.expired"', call: 'No event in 7 days, so `wait_for_any` returned the timeout value.' },
            ],
          },
        },
        { branch: 'result', clauses: { '"payment.success"': [{ step: 'fulfill', ms: 800 }], _: [{ step: 'cancel', ms: 600 }] } },
      ],
    },
  },
  {
    slug: 'batch',
    heading: 'Batch Processing',
    file: 'bulk_emailer.ex',
    spec: {
      workflow: 'send_campaign',
      module: 'MyApp.BulkEmailer',
      nodes: [{ step: 'load', ms: 600 }, { step: 'send_emails', ms: 2600 }],
    },
  },
  {
    slug: 'daily-report',
    heading: 'Scheduled Reports',
    file: 'daily_report.ex',
    spec: {
      workflow: 'daily_sales_report',
      module: 'MyApp.DailyReport',
      intro: 'The scheduler started a run: cron `0 9 * * *`, America/New_York.',
      nodes: [{ step: 'generate', ms: 1400 }, { step: 'distribute', ms: 900 }],
    },
  },
];

// `readme` is the durable/README.md body (the docs collection's `docs` entry).
export function examples(readme: string) {
  return EXAMPLES.map((e) => ({ ...e, ...section(readme, `### ${e.heading}`) }));
}
