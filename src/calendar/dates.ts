// Small date helpers for the calendar. Weeks run Monday → Sunday.

export const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
export const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

// A month is identified by its year and month number (0 = January, 11 = December).
export interface YearMonth {
  year: number;
  month: number;
}

// Move a month forward/backward, e.g. addMonths({2026, 0}, -1) → December 2025.
export function addMonths({ year, month }: YearMonth, count: number): YearMonth {
  const d = new Date(year, month + count, 1);
  return { year: d.getFullYear(), month: d.getMonth() };
}

export function thisMonth(): YearMonth {
  const now = new Date();
  return { year: now.getFullYear(), month: now.getMonth() };
}

// A date as text like "2026-10-01". Used as the key when saving things for a day.
export function dateKey(d: Date): string {
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${mm}-${dd}`;
}

export function todayKey(): string {
  return dateKey(new Date());
}

// All the days to show for a month: full weeks from the Monday on/before the 1st
// to the Sunday on/after the last day (so some days belong to the next/previous month).
export function monthGrid({ year, month }: YearMonth): Date[] {
  const first = new Date(year, month, 1);
  const daysBack = (first.getDay() + 6) % 7; // getDay(): Sunday = 0, so shift to Monday = 0
  const start = new Date(year, month, 1 - daysBack);
  const last = new Date(year, month + 1, 0);
  const daysForward = 6 - ((last.getDay() + 6) % 7);
  const total = daysBack + last.getDate() + daysForward;
  return Array.from(
    { length: total },
    (_, i) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + i),
  );
}

// "2026-10-01" → a Date at midnight that day.
export function parseKey(key: string): Date {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(y, m - 1, d);
}

// "2026-10-01" → "Oct 1"
export function formatShortDate(key: string): string {
  return parseKey(key).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

// "2026-10-01" → "Thursday, October 1"
export function formatLongDate(key: string): string {
  return parseKey(key).toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
}

// "14:30" → "2:30pm" (or "14:30" style, depending on your device's settings)
export function formatTime(time: string): string {
  const [h, m] = time.split(':').map(Number);
  return new Date(2000, 0, 1, h, m).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}
