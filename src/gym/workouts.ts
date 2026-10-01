// Gym rules and templates: which workout each weekday gets, and the exercise lists.
import { db, getSetting, setSetting, type WorkoutRecord, type WorkoutRow, type WorkoutType } from '../db';

export const GYM_COLOR = '#A85868'; // the red (gym) color
export const EVENT_COLOR = '#90D5FF'; // the blue (events) color

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
    rows: names.map((name) => ({ name, reps: '', weight: '' })),
    updatedAt: Date.now(),
  };
}

// True if anything was actually logged (otherwise we don't keep the workout).
export function hasContent(w: WorkoutRecord): boolean {
  if (w.customName.trim()) return true;
  return w.rows.some((r) =>
    w.type === 'custom' ? r.name.trim() || r.reps.trim() || r.weight.trim() : r.reps.trim() || r.weight.trim(),
  );
}

// Save a workout, or delete it if it's empty.
export function saveWorkout(w: WorkoutRecord) {
  if (!hasContent(w)) return db.workouts.delete(w.date);
  return db.workouts.put({ ...w, updatedAt: Date.now() });
}

// Same exercise written slightly differently ("lat pulldown " vs "Lat Pulldown")
// counts as the same exercise in Progress charts.
export function normalizeExerciseName(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLowerCase();
}

export type { WorkoutRow };
