// Moving everything to another browser.
// "Copy" turns ALL your data (whiteboards, slideshows and their videos, calendar events,
// reminders, holiday labels, workouts, settings) into one block of text. In the other browser,
// pasting that text puts it all back exactly as it was.
import { db } from './db';

const TABLES = ['whiteboard', 'settings', 'events', 'workouts', 'spans', 'slideshows', 'slides', 'videos'] as const;
const FORMAT = 'my-stuff-backup';

const blobToDataURL = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result as string);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });

const dataURLToBlob = async (url: string) => (await fetch(url)).blob();

// Everything, as text.
export async function exportAll(): Promise<string> {
  const tables: Record<string, unknown[]> = {};
  for (const name of TABLES) {
    const rows = await db.table(name).toArray();
    // Video files can't go into text directly, so they're written out as data URLs.
    tables[name] =
      name === 'videos'
        ? await Promise.all(rows.map(async (v) => ({ ...v, blob: await blobToDataURL(v.blob) })))
        : rows;
  }
  return JSON.stringify({ format: FORMAT, version: 1, exportedAt: new Date().toISOString(), tables });
}

// How many things are in a backup (shown before you restore it), or an error message.
export function describeBackup(text: string): { ok: true; summary: string } | { ok: false; error: string } {
  let data: { format?: string; tables?: Record<string, unknown[]> };
  try {
    data = JSON.parse(text);
  } catch {
    return { ok: false, error: "That isn't a backup. Paste the whole text you copied." };
  }
  if (data?.format !== FORMAT || !data.tables) return { ok: false, error: "That isn't a backup from this site." };
  const n = (t: string) => data.tables![t]?.length ?? 0;
  return {
    ok: true,
    summary: `${n('whiteboard')} boards, ${n('slideshows')} slideshows (${n('slides')} pages, ${n('videos')} videos), ${n('events')} events & reminders, ${n('spans')} labels, ${n('workouts')} workout days`,
  };
}

// Replace everything in this browser with the backup.
export async function importAll(text: string): Promise<void> {
  const data = JSON.parse(text) as { tables: Record<string, Record<string, unknown>[]> };
  // Turn videos back into files before starting (fetch can't run inside the save below).
  const videos = await Promise.all(
    (data.tables.videos ?? []).map(async (v) => ({ ...v, blob: await dataURLToBlob(v.blob as string) })),
  );
  await db.transaction('rw', TABLES.map((t) => db.table(t)), async () => {
    for (const name of TABLES) {
      const rows = name === 'videos' ? videos : (data.tables[name] ?? []);
      await db.table(name).clear();
      await db.table(name).bulkPut(rows);
    }
  });
}
