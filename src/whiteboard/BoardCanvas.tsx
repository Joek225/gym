// One Excalidraw board. Loads its drawing from the database and auto-saves changes.
import { useEffect, useRef, useState } from 'react';
import { Excalidraw, FONT_FAMILY, MainMenu, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import type { ExcalidrawInitialDataState as InitialData } from '@excalidraw/excalidraw/types';
import { db } from '../db';

// Excalidraw's own type for "the change callback".
type OnChange = NonNullable<Parameters<typeof Excalidraw>[0]['onChange']>;

const SAVE_DELAY_MS = 500; // wait until you pause drawing for half a second, then save

// Settings applied every time a board opens.
const START_SETTINGS = {
  // New text uses Avenir (see the "Helvetica" font rule in styles.css for how).
  currentItemFontFamily: FONT_FAMILY.Helvetica,
};

// Background for a brand-new board. Excalidraw's dark mode flips canvas colors,
// so this light color shows up on screen as the site's dark grey (#282a37).
const NEW_BOARD_BACKGROUND = '#dfe2f1';

export default function BoardCanvas({ boardId }: { boardId: string }) {
  // undefined = still loading from the database.
  const [initialData, setInitialData] = useState<InitialData | undefined>(undefined);
  const saveTimer = useRef<number | undefined>(undefined);
  const pendingSave = useRef<(() => void) | null>(null);
  const lastSaved = useRef<string>('');

  // 1) When the board opens, load its saved drawing.
  useEffect(() => {
    // Load the Avenir font first, so text is measured with the right letter widths.
    const fontReady = document.fonts.load('20px Helvetica').catch(() => {});
    Promise.all([db.whiteboard.get(boardId), fontReady]).then(([record]) => {
      const saved = record?.data as InitialData | null | undefined;
      if (saved) lastSaved.current = JSON.stringify(saved);
      setInitialData({
        ...saved,
        appState: {
          viewBackgroundColor: NEW_BOARD_BACKGROUND,
          ...saved?.appState,
          ...START_SETTINGS,
        },
      });
    });
  }, [boardId]);

  // 2) Make sure a pending save still happens if you switch boards/tabs or close the page.
  useEffect(() => {
    const flush = () => {
      window.clearTimeout(saveTimer.current);
      pendingSave.current?.();
      pendingSave.current = null;
    };
    window.addEventListener('pagehide', flush);
    document.addEventListener('visibilitychange', flush);
    return () => {
      flush(); // leaving this board
      window.removeEventListener('pagehide', flush);
      document.removeEventListener('visibilitychange', flush);
    };
  }, []);

  // 3) Excalidraw calls this on every change (each stroke, typed letter, even mouse moves).
  //    We wait for a short pause, then save to the database.
  const handleChange: OnChange = (elements, appState, files) => {
    pendingSave.current = () => {
      const json = serializeAsJSON(elements, appState, files, 'local');
      if (json === lastSaved.current) return; // nothing really changed, skip
      lastSaved.current = json;
      db.whiteboard.update(boardId, { data: JSON.parse(json), updatedAt: Date.now() });
    };
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      pendingSave.current?.();
      pendingSave.current = null;
    }, SAVE_DELAY_MS);
  };

  if (initialData === undefined) return <div className="placeholder">Loading…</div>;

  return (
    <Excalidraw
      initialData={initialData}
      onChange={handleChange}
      theme="dark"
      UIOptions={{
        // Hide file buttons: everything already saves automatically.
        canvasActions: {
          loadScene: false,
          saveToActiveFile: false,
          export: false,
          saveAsImage: false,
          toggleTheme: null,
        },
      }}
    >
      {/* The ☰ menu: only the items that are useful here. */}
      <MainMenu>
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.DefaultItems.ChangeCanvasBackground />
      </MainMenu>
    </Excalidraw>
  );
}
