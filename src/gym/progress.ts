// Turns logged workouts into one history per exercise, for the Progress graphs.
import type { WorkoutRecord } from '../db';
import { NEW_TEMPLATES, isLogged, normalizeExerciseName } from './workouts';

// One day of one exercise.
export interface LiftPoint {
  date: string; // "2026-11-06"
  time: number; // the same day as a number, for the graph's time axis
  heaviest: number; // heaviest weight lifted that day (kg)
  volume: number; // weight × reps, added up over that day's sets (kg)
  bestSet: string; // e.g. "62kg × 8"
  sets: number;
}

export interface LiftHistory {
  key: string; // the name, lower-cased, used to group spellings together
  name: string; // the name as last written
  side: 'upper' | 'lower';
  current: boolean; // part of the current split (shown first)
  points: LiftPoint[]; // oldest first
}

const num = (s: string) => {
  const n = parseFloat(s);
  return Number.isFinite(n) ? n : null;
};

const dayTime = (date: string) => {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d).getTime();
};

// Every exercise logged on an Upper or Lower day, with its history.
export function liftHistories(workouts: WorkoutRecord[]): LiftHistory[] {
  const byKey = new Map<string, LiftHistory>();
  const sorted = [...workouts].sort((a, b) => a.date.localeCompare(b.date));
  for (const w of sorted) {
    if (w.type !== 'upper' && w.type !== 'lower') continue; // Custom days aren't the fixed split
    const day = new Map<string, { name: string; rows: { weight: number; reps: number }[] }>();
    for (const r of w.rows) {
      const weight = num(r.weight);
      const reps = num(r.reps);
      if (!r.name.trim() || !isLogged(r) || weight === null || reps === null) continue;
      const key = normalizeExerciseName(r.name);
      const entry = day.get(key) ?? { name: r.name.trim(), rows: [] };
      entry.rows.push({ weight, reps });
      day.set(key, entry);
    }
    for (const [key, { name, rows }] of day) {
      const best = rows.reduce((a, b) => (b.weight > a.weight || (b.weight === a.weight && b.reps > a.reps) ? b : a));
      const point: LiftPoint = {
        date: w.date,
        time: dayTime(w.date),
        heaviest: best.weight,
        volume: rows.reduce((sum, r) => sum + r.weight * r.reps, 0),
        bestSet: `${best.weight}kg × ${best.reps}`,
        sets: rows.length,
      };
      const history = byKey.get(key) ?? { key, name, side: w.type, current: false, points: [] };
      history.name = name; // latest spelling wins
      history.side = w.type;
      history.points.push(point);
      byKey.set(key, history);
    }
  }
  // Current split first, in the order you do it; anything older after, A–Z.
  const order = (side: 'upper' | 'lower') => [...new Set(NEW_TEMPLATES[side].map(normalizeExerciseName))];
  const result: LiftHistory[] = [];
  for (const side of ['upper', 'lower'] as const) {
    const current = order(side);
    const mine = [...byKey.values()].filter((h) => h.side === side);
    for (const key of current) {
      const h = mine.find((x) => x.key === key);
      if (h) result.push({ ...h, current: true });
    }
    result.push(...mine.filter((h) => !current.includes(h.key)).sort((a, b) => a.name.localeCompare(b.name)));
  }
  return result;
}
