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

// School blocks you can pick instead of a clock time (shown in the time dropdown).
export const BLOCKS = ['Flex', 'Block 1', 'Block 2', 'Block 3', 'Block 4', 'After school'];

// When each block starts, in minutes after midnight, so events can be put in time order.
// Wednesday and Thursday start later (Flex 8:00–8:30, Block 1 8:30–9:50).
function blockStart(block: string, weekday: number): number {
  const wedThu = weekday === 3 || weekday === 4;
  switch (block) {
    case 'Flex':
      return 8 * 60; // 8:00
    case 'Block 1':
      return wedThu ? 8 * 60 + 30 : 8 * 60 + 1; // 8:30 Wed/Thu, otherwise 8:00 (just after Flex)
    case 'Block 2':
      return 9 * 60 + 30; // 9:30
    case 'Block 3':
      return 12 * 60 + 10; // 12:10
    case 'Block 4':
      return 13 * 60 + 40; // 1:40
    case 'After school':
      return 15 * 60; // 3:00, when school finishes
    default:
      return -1;
  }
}

const CLOCK = /^(\d{1,2}):(\d{2})$/;
const RANGE = /^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$/; // "06:00-10:00"

function clockText(time: string): string {
  const [h, m] = time.split(':').map(Number);
  return new Date(2000, 0, 1, h, m).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

// An event's time for showing: "14:30" → "2:30 PM", "06:00-10:00" → "6:00 AM – 10:00 AM",
// or a block name as is ("Block 2").
export function formatTime(time: string): string {
  const range = time.match(RANGE);
  if (range) return `${clockText(range[1])} – ${clockText(range[2])}`;
  if (CLOCK.test(time)) return clockText(time);
  return time;
}

// For putting a day's events in time order (blocks placed at their real times).
// Events with no time go last.
export function timeOrder(time: string, date: string): number {
  if (!time) return 24 * 60;
  const start = time.match(RANGE)?.[1] ?? time;
  const clock = start.match(CLOCK);
  if (clock) return Number(clock[1]) * 60 + Number(clock[2]);
  const b = blockStart(time, parseKey(date).getDay());
  return b >= 0 ? b : 24 * 60 - 1;
}

// Compare two events (date first, then time of day) — for .sort().
export function byDateAndTime(a: { date: string; time: string }, b: { date: string; time: string }): number {
  return a.date.localeCompare(b.date) || timeOrder(a.time, a.date) - timeOrder(b.time, b.date);
}

// The date `days` days after "2026-10-01".
export function addDays(key: string, days: number): string {
  const d = parseKey(key);
  return dateKey(new Date(d.getFullYear(), d.getMonth(), d.getDate() + days));
}
