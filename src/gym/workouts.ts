// Gym rules and templates: which workout each weekday gets, and the exercise lists.
import {
  db,
  getSetting,
  setSetting,
  type Cardio,
  type WorkoutRecord,
  type WorkoutRow,
  type WorkoutType,
} from '../db';

export const GYM_COLOR = '#A85868'; // the red (gym) color
export const CUSTOM_GYM_COLOR = '#6B2A3A'; // darker red for Custom-day banners (Wed/Sat/Sun)
export const CARDIO_COLOR = '#E9C9C9'; // pale pink for cardio
export const CARDIO_TEXT = '#5A2833'; // dark text that reads well on the pale pink
export const EVENT_COLOR = '#90D5FF'; // the blue (events) color
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
  const [y, m, d] = date.split('-').map(Number);
  return TYPE_BY_WEEKDAY[new Date(y, m - 1, d).getDay()];
}

// The calendar banner color: normal red for Upper/Lower, darker red for Custom days.
// (Only the banners in the big month; everything else uses the normal red.)
export function workoutColor(w: WorkoutRecord): string {
  return w.type === 'custom' ? CUSTOM_GYM_COLOR : GYM_COLOR;
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

export const DEFAULT_TEMPLATES: Templates = {
  upper: [
    'Lat Pulldown',
    'T-Bar Row',
    'Smith Shoulder Press',
    'Incline Chest Machine Press',
    'Cable Chest Fly',
    'Hammer Curl',
    'Preacher Curl',
    'Tricep Pushdown',
    'Lateral Raise',
  ],
  lower: ['Deadlift', 'Quad Extension', 'Lying Hamstring Curl', 'Angled Hack Squat', 'Hip Thrust'],
};

export async function getTemplates(): Promise<Templates> {
  return (await getSetting<Templates>('templates')) ?? DEFAULT_TEMPLATES;
}

export function saveTemplates(t: Templates) {
  return setSetting('templates', t);
}

// A new workout for a date. Upper/Lower days start with the template's exercise names
// (copied, so later template changes don't touch this workout).
export async function newWorkout(date: string): Promise<WorkoutRecord> {
  const type = workoutTypeFor(date);
  const templates = await getTemplates();
  const names = type === 'custom' ? [''] : templates[type];
  return {
    date,
    type,
    customName: '',
    rows: names.map((name) => ({ name, reps: '', partial: '', weight: '' })),
    updatedAt: Date.now(),
  };
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
  return !!c && !!(c.speed || c.incline || c.hours || c.mins);
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

// One line as text: "Lat Pulldown - 10 - 2 - 60kg" (partial reps left out if empty).
export function formatLine(r: WorkoutRow): string {
  const weight = r.weight ? `${r.weight}kg` : '';
  return [r.name, r.reps, r.partial, weight].filter((x) => x && x.trim()).join(' - ');
}

// Same exercise written slightly differently ("lat pulldown " vs "Lat Pulldown")
// counts as the same exercise in Progress charts.
export function normalizeExerciseName(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLowerCase();
}

export type { WorkoutRow };
