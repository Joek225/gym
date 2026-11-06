// Gym rules and templates: which workout each weekday gets, and the exercise lists.
import {
  db,
  type Cardio,
  type WorkoutRecord,
  type WorkoutRow,
  type WorkoutType,
} from '../db';

export const GYM_COLOR = '#A85868'; // the red (gym) color
export const CUSTOM_GYM_COLOR = '#6B2A3A'; // darker red for Custom-day banners (Wed/Sat/Sun)
export const CARDIO_COLOR = '#47333B'; // dark plum for cardio
export const CARDIO_TEXT = '#FFFFFF'; // white text on it
export const EVENT_COLOR = '#90D5FF'; // the blue (events) color
export const REMINDER_COLOR = '#313D49'; // slate blue-grey for reminders
// Slightly darker versions for the big zoomed-in day, so white text reads well on both.
export const GYM_COLOR_DARK = '#8F4656';
export const EVENT_COLOR_DARK = '#3E8DBF';

// Weekday → workout type. getDay(): Sunday = 0, Monday = 1, ... Saturday = 6.
const TYPE_BY_WEEKDAY: WorkoutType[] = [
  'custom', // Sunday
  'lower', // Monday
  'upper', // Tuesday
  'custom', // Wednesday
  'lower', // Thursday
  'upper', // Friday
  'custom', // Saturday
];

// "2026-10-01" → the workout type for that day.
export function workoutTypeFor(date: string): WorkoutType {
  return TYPE_BY_WEEKDAY[parseDate(date).getDay()];
}

// The calendar banner color: normal red on Mon/Tue/Thu/Fri (even a Custom holiday workout),
// darker red on Wed/Sat/Sun. (Only the banners in the big month; everything else uses the normal red.)
export function workoutColor(w: WorkoutRecord): string {
  return workoutTypeFor(w.date) === 'custom' ? CUSTOM_GYM_COLOR : GYM_COLOR;
}

// The label shown on the red banner: UPPER, LOWER, or the custom name.
export function workoutLabel(w: WorkoutRecord): string {
  if (w.type === 'custom') return w.customName.trim() || 'CUSTOM';
  return w.type.toUpperCase();
}

// ---- Templates (the exercise lists that pre-fill Upper and Lower days) ----
export interface Templates {
  upper: string[];
  lower: string[];
}

// The exercise lists for Upper and Lower days, in the order you do them.
// To change them, edit these lists. (Changes only affect NEW workouts.)
export const TEMPLATES: Templates = {
  upper: [
    'Lat Pulldown',
    'T-Bar Row',
    'Incline Chest Machine Press',
    'Cable Chest Fly',
    'Smith Shoulder Press',
    'Tricep Pushdown',
    'Tricep Overhead Extension',
    'Preacher Curl',
    'Hammer Curl',
    'Lateral Raise',
  ],
  lower: ['Deadlift', 'Quad Extension', 'Lying Hamstring Curl', 'Hack Squat', 'Hip Thrust'],
};

// The split from 6 Nov 2026 on: one line per set, in this order (a name twice = 2 sets).
export const NEW_SPLIT_FROM = '2026-11-06';
export const NEW_TEMPLATES: Templates = {
  upper: [
    'T-Bar Row',
    'T-Bar Row',
    'Machine Chest Press',
    'Machine Chest Press',
    'Lat Pulldown',
    'Single Arm Row',
    'Cable Chest Fly',
    'Shoulder Press',
    'Hammer Curl',
    'Preacher Curl',
    'Tricep Pushdown',
    'Tricep Extension',
  ],
  lower: [
    'Sissy Squat',
    'Sissy Squat',
    'Leg Extension',
    'Leg Extension',
    'Lying Leg Curl',
    'Lying Leg Curl',
    'Deadlift',
  ],
};

// The exercise list for a day: the new split from NEW_SPLIT_FROM, the old one before.
export function templateFor(type: 'upper' | 'lower', date: string): string[] {
  return (date >= NEW_SPLIT_FROM ? NEW_TEMPLATES : TEMPLATES)[type];
}

// Your usual gym, filled in on normal (non-holiday) Monday–Friday workouts.
export const HOME_GYM = 'apex';
const isWeekday = (date: string) => {
  const day = parseDate(date).getDay();
  return day >= 1 && day <= 5;
};
const parseDate = (date: string) => {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d);
};

// Exercises you do a few different ways: the sheet asks which one before you log it,
// and the choice becomes part of the name (e.g. "Cable Lateral Raise").
export const VARIANTS: Record<string, string[]> = {
  'Lateral Raise': ['Cable', 'Dumbbell'],
};

// True if a blue multi-day label (e.g. a holiday) covers this date.
// On those days you're at a different gym, so every day gets a Custom workout.
export async function isHoliday(date: string): Promise<boolean> {
  return (await db.spans.where('start').belowOrEqual(date).filter((sp) => sp.end >= date).count()) > 0;
}

// True if this is a normal Mon/Tue/Thu/Fri Upper/Lower workout (what the small calendars show).
export function isStandardWorkout(w: WorkoutRecord): boolean {
  return w.type !== 'custom' && w.type === workoutTypeFor(w.date);
}

// A new workout for a date. Upper/Lower days start with the template's exercise names
// (copied, so later template changes don't touch this workout). Holiday days are Custom.
export async function newWorkout(date: string): Promise<WorkoutRecord> {
  const holiday = await isHoliday(date);
  const type = holiday ? 'custom' : workoutTypeFor(date);
  const names = type === 'custom' ? [''] : templateFor(type, date);
  const location = holiday ? '' : defaultLocation(date);
  return {
    date,
    type,
    customName: '',
    rows: names.map((name) => ({ name, reps: '', partial: '', weight: '' })),
    location,
    updatedAt: Date.now(),
  };
}

const defaultLocation = (date: string) => (isWeekday(date) ? HOME_GYM : '');

// The workout to open for a date: the saved one, or a new one. Lines you've logged are never
// changed. One with only cardio is switched to Custom if the day is now a holiday. From
// NEW_SPLIT_FROM on, an Upper/Lower workout shows the new exercise list, keeping logged lines.
export async function workoutToEdit(date: string, saved?: WorkoutRecord): Promise<WorkoutRecord> {
  if (!saved) return newWorkout(date);
  const holiday = await isHoliday(date);
  let w = saved;
  if (!hasLifts(saved) && saved.type !== 'custom' && holiday) w = { ...(await newWorkout(date)), cardio: saved.cardio };
  else if (w.type !== 'custom' && date >= NEW_SPLIT_FROM) w = { ...w, rows: withTemplate(w.rows, templateFor(w.type, date)) };
  // Older workouts have no location yet: fill in your usual gym on normal weekdays.
  if (w.location === undefined && !holiday) w = { ...w, location: defaultLocation(date) };
  return w;
}

// The template's lines in order, each filled from a matching logged line when there is one;
// logged lines that aren't in the template stay, at the end.
function withTemplate(rows: WorkoutRow[], names: string[]): WorkoutRow[] {
  const logged = rows.filter(isLogged);
  const used = new Set<WorkoutRow>();
  const out = names.map((name) => {
    const match = logged.find((r) => !used.has(r) && normalizeExerciseName(r.name) === normalizeExerciseName(name));
    if (match) used.add(match);
    return match ?? { name, reps: '', partial: '', weight: '' };
  });
  return [...out, ...logged.filter((r) => !used.has(r))];
}

// True if a line has any numbers/weight filled in.
export function isLogged(r: WorkoutRow): boolean {
  return !!(r.reps.trim() || r.partial?.trim() || r.weight.trim());
}

// True if any lifts were logged (or a Custom day was named): this gets the red banner.
export function hasLifts(w: WorkoutRecord): boolean {
  return !!w.customName.trim() || w.rows.some(isLogged);
}

// True if any cardio box is filled in.
export function hasCardio(c?: Cardio): boolean {
  return !!c && !!(c.speed || c.incline || c.hours || c.mins || c.weight);
}

// Cardio as text: "10 - 12 - 0:30" (speed - incline - hours:mins).
export function formatCardio(c: Cardio): string {
  const time = c.hours || c.mins ? `${c.hours || '0'}:${(c.mins || '0').padStart(2, '0')}` : '';
  return [c.speed, c.incline, time].filter(Boolean).join(' - ');
}

// True if anything was actually logged (otherwise we don't keep the workout).
export function hasContent(w: WorkoutRecord): boolean {
  if (w.customName.trim() || hasCardio(w.cardio)) return true;
  return w.rows.some((r) => isLogged(r) || (w.type === 'custom' && r.name.trim()));
}

// Save a workout, or delete it if it's empty. Lines with no exercise name are dropped.
export function saveWorkout(w: WorkoutRecord) {
  const clean = { ...w, rows: w.rows.filter((r) => r.name.trim()) };
  if (!hasContent(clean)) return db.workouts.delete(w.date);
  return db.workouts.put({ ...clean, updatedAt: Date.now() });
}

// One line as text: "Lat Pulldown - 60kg - 10 - 2" (partial reps left out if empty).
export function formatLine(r: WorkoutRow): string {
  const weight = r.weight ? `${r.weight}kg` : '';
  return [r.name, weight, r.reps, r.partial].filter((x) => x && x.trim()).join(' - ');
}

// Same exercise written slightly differently ("lat pulldown " vs "Lat Pulldown")
// counts as the same exercise in Progress charts.
export function normalizeExerciseName(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLowerCase();
}

export type { WorkoutRow };
