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

// Small app-wide settings, e.g. which board was open last.
export interface SettingRecord {
  key: string;
  value: unknown;
}

class AppDatabase extends Dexie {
  whiteboard!: Table<WhiteboardRecord, string>;
  settings!: Table<SettingRecord, string>;

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
