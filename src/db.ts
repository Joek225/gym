// The browser database where ALL the site's data is saved (IndexedDB, via the Dexie library).
// Data stays on this device/browser even after closing the tab.
// Later phases add more tables here (categories, events, workouts, ...).
import Dexie, { type Table } from 'dexie';

// One saved drawing. We only have one whiteboard, so its id is always "main".
export interface WhiteboardRecord {
  id: string;
  data: unknown; // the drawing in Excalidraw's own save format
  updatedAt: number; // when it was last saved (milliseconds since 1970)
}

class AppDatabase extends Dexie {
  whiteboard!: Table<WhiteboardRecord, string>;

  constructor() {
    super('gym-app');
    // Version 1: just the whiteboard. "id" is the key used to find a record.
    this.version(1).stores({
      whiteboard: 'id',
    });
  }
}

export const db = new AppDatabase();
