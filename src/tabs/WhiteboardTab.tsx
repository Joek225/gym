// Whiteboard tab: an Excalidraw drawing board that saves itself automatically.
import { useEffect, useRef, useState } from 'react';
import { Excalidraw, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import { db } from '../db';

// Excalidraw's own type for "what to show when it first opens".
type InitialData = Parameters<typeof Excalidraw>[0]['initialData'];

const WHITEBOARD_ID = 'main';
const SAVE_DELAY_MS = 500; // wait until you pause drawing for half a second, then save

// Background for a brand-new board. Excalidraw's dark mode flips canvas colors,
// so this light color shows up on screen as the site's dark grey (#282a37).
const NEW_BOARD: InitialData = { appState: { viewBackgroundColor: '#dfe2f1' } };

export default function WhiteboardTab() {
  // undefined = still loading from the database; null = nothing saved yet.
  const [initialData, setInitialData] = useState<InitialData | null | undefined>(undefined);
  const saveTimer = useRef<number | undefined>(undefined);
  const pendingSave = useRef<(() => void) | null>(null);
  const lastSaved = useRef<string>('');

  // 1) When the tab opens, load the saved drawing (if any).
  useEffect(() => {
    db.whiteboard.get(WHITEBOARD_ID).then((record) => {
      if (record) lastSaved.current = JSON.stringify(record.data);
      setInitialData(record ? (record.data as InitialData) : null);
    });
  }, []);

  // 2) Make sure a pending save still happens if you switch tabs or close the page.
  useEffect(() => {
    const flush = () => {
      window.clearTimeout(saveTimer.current);
      pendingSave.current?.();
      pendingSave.current = null;
    };
    window.addEventListener('pagehide', flush);
    document.addEventListener('visibilitychange', flush);
    return () => {
      flush(); // leaving the Whiteboard tab
      window.removeEventListener('pagehide', flush);
      document.removeEventListener('visibilitychange', flush);
    };
  }, []);

  // 3) Excalidraw calls this on every change (each stroke, typed letter, even mouse moves).
  //    We wait for a short pause, then save to the database.
  const handleChange: NonNullable<Parameters<typeof Excalidraw>[0]['onChange']> = (
    elements,
    appState,
    files,
  ) => {
    pendingSave.current = () => {
      const json = serializeAsJSON(elements, appState, files, 'local');
      if (json === lastSaved.current) return; // nothing really changed, skip
      lastSaved.current = json;
      db.whiteboard.put({ id: WHITEBOARD_ID, data: JSON.parse(json), updatedAt: Date.now() });
    };
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      pendingSave.current?.();
      pendingSave.current = null;
    }, SAVE_DELAY_MS);
  };

  if (initialData === undefined) return <div className="placeholder">Loading…</div>;

  return (
    <div className="whiteboard">
      <Excalidraw
        initialData={initialData ?? NEW_BOARD}
        onChange={handleChange}
        theme="dark"
      />
    </div>
  );
}
