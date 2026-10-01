// The browser database where ALL the site's data is saved (IndexedDB, via the Dexie library).
// Data stays on this device/browser even after closing the tab.
// Later phases add more tables here (categories, events, workouts, ...).
import Dexie, { type Table } from 'dexie';

// One whiteboard (you can have several).
export interface WhiteboardRecord {
  id: string;
  name: string; // shown on the board's button, e.g. "Board 1"
  data: unknown; // the drawing in Excalidraw's own save format (null = empty board)
  createdAt: number; // used to keep boards in the order you made them
  updatedAt: number; // when it was last saved (milliseconds since 1970)
}

// A calendar event (blue) or reminder (dark blue) for a day.
export interface EventRecord {
  id: string;
  kind?: 'event' | 'reminder'; // missing = event (older entries)
  date: string; // "2026-10-01"
  title: string;
  time: string; // "09:30", a block like "Block 2", "06:00-10:00", or "" if no time
  notes: string;
  struck: boolean; // crossed out on Board 1 (hidden from the board, kept in the calendar)
  createdAt: number;
}

// One line of a workout: exercise - reps - partial reps - weight (kg). Empty text = not filled in.
export interface WorkoutRow {
  name: string;
  reps: string;
  partial?: string; // optional partial reps (older workouts don't have this)
  weight: string;
}

export type WorkoutType = 'upper' | 'lower' | 'custom';

// Cardio for a day: speed - incline - hours:mins (all text so boxes can be left empty).
export interface Cardio {
  speed: string;
  incline: string;
  hours: string;
  mins: string;
}

// A day's workout (the red side of a day). One per date.
export interface WorkoutRecord {
  date: string; // "2026-10-01"
  type: WorkoutType;
  customName: string; // only used for custom days, e.g. "Push" or "Cardio"
  rows: WorkoutRow[];
  cardio?: Cardio; // older workouts don't have this
  updatedAt: number;
}

// A label across several days, e.g. "Holiday" from Oct 8 to Oct 10 (the long blue bar).
export interface SpanRecord {
  id: string;
  start: string; // first day, "2026-10-08"
  end: string; // last day, "2026-10-10"
  label: string;
  createdAt: number;
}

export const TODO_BOARD_NAME = 'To do list';

// Small app-wide settings, e.g. which board was open last.
export interface SettingRecord {
  key: string;
  value: unknown;
}

class AppDatabase extends Dexie {
  whiteboard!: Table<WhiteboardRecord, string>;
  settings!: Table<SettingRecord, string>;
  events!: Table<EventRecord, string>;
  workouts!: Table<WorkoutRecord, string>;
  spans!: Table<SpanRecord, string>;

  constructor() {
    super('gym-app');
    // Version 1: one whiteboard. "id" is the key used to find a record.
    this.version(1).stores({
      whiteboard: 'id',
    });
    // Version 2: several whiteboards (each gets a name) + a settings table.
    this.version(2)
      .stores({
        whiteboard: 'id, createdAt',
        settings: 'key',
      })
      .upgrade((tx) =>
        // Give the board you already drew on a name, so nothing is lost.
        tx
          .table('whiteboard')
          .toCollection()
          .modify((board) => {
            board.name ??= 'Board 1';
            board.createdAt ??= board.updatedAt ?? Date.now();
            // Boards from before the dark theme had a white background; make them grey.
            if (board.data?.appState?.viewBackgroundColor === '#ffffff') {
              board.data.appState.viewBackgroundColor = '#dfe2f1';
            }
          }),
      );
    // Version 3: calendar events and workouts.
    this.version(3).stores({
      events: 'id, date',
      workouts: 'date',
    });
    // Version 4: the first board becomes the "To do list".
    this.version(4)
      .stores({})
      .upgrade(async (tx) => {
        const first = await tx.table('whiteboard').orderBy('createdAt').first();
        if (first && first.name === 'Board 1') {
          await tx.table('whiteboard').update(first.id, { name: TODO_BOARD_NAME });
        }
      });
    // Version 5: multi-day labels (blue bars).
    this.version(5).stores({
      spans: 'id, start',
    });
  }
}

export const db = new AppDatabase();

// Helpers to read/write one setting.
export async function getSetting<T>(key: string): Promise<T | undefined> {
  return (await db.settings.get(key))?.value as T | undefined;
}
export function setSetting(key: string, value: unknown) {
  return db.settings.put({ key, value });
}
