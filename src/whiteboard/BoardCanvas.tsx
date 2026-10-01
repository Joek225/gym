// One Excalidraw board. Loads its drawing from the database and auto-saves changes.
// Also adds the stroke eraser, our number hotkeys, and (on Board 1) the upcoming-events list.
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  CaptureUpdateAction,
  Excalidraw,
  FONT_FAMILY,
  MainMenu,
  serializeAsJSON,
} from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import type {
  ExcalidrawImperativeAPI,
  ExcalidrawInitialDataState as InitialData,
} from '@excalidraw/excalidraw/types';
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types';
import { db, type EventRecord } from '../db';
import { todayKey } from '../calendar/dates';
import { eraseAlong } from './strokeEraser';
import { STROKE_ERASER, StrokeEraserButton, useToolHotkeys } from './toolbar';
import UpcomingEvents, { type UpcomingEventsHandle } from './UpcomingEvents';

// Excalidraw's own types for its callbacks.
type Props = Parameters<typeof Excalidraw>[0];
type OnChange = NonNullable<Props['onChange']>;
type OnPointerUpdate = NonNullable<Props['onPointerUpdate']>;

const SAVE_DELAY_MS = 500; // wait until you pause drawing for half a second, then save
const ERASER_SIZE = 12; // stroke eraser radius, in screen pixels

// Settings applied every time a board opens.
const START_SETTINGS = {
  // New text uses Avenir (see the "Helvetica" font rule in styles.css for how).
  currentItemFontFamily: FONT_FAMILY.Helvetica,
};

// Background for a brand-new board. Excalidraw's dark mode flips canvas colors,
// so this light color shows up on screen as the site's dark grey (#282a37).
const NEW_BOARD_BACKGROUND = '#dfe2f1';

export default function BoardCanvas({ boardId, isFirstBoard }: { boardId: string; isFirstBoard: boolean }) {
  // undefined = still loading from the database.
  const [initialData, setInitialData] = useState<InitialData | undefined>(undefined);
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null);
  const [container, setContainer] = useState<HTMLDivElement | null>(null);
  const saveTimer = useRef<number | undefined>(undefined);
  const pendingSave = useRef<(() => void) | null>(null);
  const lastSaved = useRef<string>('');

  // ---------- Loading & saving ----------

  // 1) When the board opens, load its saved drawing.
  useEffect(() => {
    // Load the Avenir font first, so text is measured with the right letter widths.
    const fontReady = document.fonts.load('20px Helvetica').catch(() => {});
    Promise.all([db.whiteboard.get(boardId), fontReady]).then(([record]) => {
      const saved = record?.data as InitialData | null | undefined;
      if (saved) lastSaved.current = JSON.stringify(saved);
      seenIds.current = new Set((saved?.elements ?? []).map((e) => e.id));
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

  // ---------- Upcoming events (Board 1 only) ----------
  const [events, setEvents] = useState<EventRecord[]>([]);
  const upcomingRef = useRef<UpcomingEventsHandle>(null);
  const seenIds = useRef(new Set<string>()); // drawings that existed before (not new lines)

  useEffect(() => {
    if (!isFirstBoard) return;
    db.events
      .where('date')
      .aboveOrEqual(todayKey()) // past events are left out
      .toArray()
      .then((list) =>
        setEvents(
          list
            .filter((e) => !e.struck)
            .sort((a, b) => (a.date + (a.time || '99')).localeCompare(b.date + (b.time || '99'))),
        ),
      );
  }, [isFirstBoard]);

  // When you finish drawing a line, check if it crosses out one of the upcoming events.
  // If so: hide that event from the board and remove the line you drew.
  const checkForCrossOut = (elements: readonly ExcalidrawElement[], appState: any) => {
    const newLines = elements.filter((el) => !seenIds.current.has(el.id));
    newLines.forEach((el) => seenIds.current.add(el.id));
    if (!isFirstBoard || !api || events.length === 0) return;

    for (const el of newLines as any[]) {
      if (el.isDeleted || !['freedraw', 'line', 'arrow'].includes(el.type)) continue;
      // The line's corners on screen.
      const zoom = appState.zoom.value;
      const xs = el.points.map((p: number[]) => (el.x + p[0] + appState.scrollX) * zoom + appState.offsetLeft);
      const ys = el.points.map((p: number[]) => (el.y + p[1] + appState.scrollY) * zoom + appState.offsetTop);
      const left = Math.min(...xs);
      const right = Math.max(...xs);
      const middleY = (Math.min(...ys) + Math.max(...ys)) / 2;
      const height = Math.max(...ys) - Math.min(...ys);

      const hit = upcomingRef.current?.rowRects().find(({ rect }) => {
        const overlap = Math.min(right, rect.right) - Math.max(left, rect.left);
        return (
          overlap > rect.width * 0.4 && // covers a good part of the row's width
          middleY > rect.top - 4 &&
          middleY < rect.bottom + 4 && // goes through the row
          height < rect.height * 2.5 // mostly sideways, not a big scribble
        );
      });
      if (!hit) continue;

      db.events.update(hit.id, { struck: true });
      setEvents((list) => list.filter((e) => e.id !== hit.id));
      api.updateScene({
        elements: api
          .getSceneElementsIncludingDeleted()
          .map((x) => (x.id === el.id ? { ...x, isDeleted: true, version: x.version + 1 } : x)),
        captureUpdate: CaptureUpdateAction.NEVER,
      });
    }
  };

  // ---------- Stroke eraser ----------
  const [strokeEraserOn, setStrokeEraserOn] = useState(false);
  const [cursor, setCursor] = useState<{ x: number; y: number } | null>(null);
  const lastErasePoint = useRef<[number, number] | null>(null);

  const selectStrokeEraser = useCallback(() => {
    // "locked" keeps the eraser selected after each rub (instead of switching back).
    api?.setActiveTool({ type: 'custom', customType: STROKE_ERASER, locked: true });
  }, [api]);

  useToolHotkeys(container, selectStrokeEraser);

  // Excalidraw tells us where the pointer is (in board coordinates) as it moves.
  const handlePointerUpdate: OnPointerUpdate = ({ pointer, button }) => {
    if (!api || !strokeEraserOn) return;
    const { scrollX, scrollY, zoom } = api.getAppState();
    setCursor({ x: (pointer.x + scrollX) * zoom.value, y: (pointer.y + scrollY) * zoom.value });

    if (button !== 'down') {
      // Finished a rub: save it as one step you can undo.
      if (lastErasePoint.current) {
        api.updateScene({
          elements: api.getSceneElementsIncludingDeleted(),
          captureUpdate: CaptureUpdateAction.IMMEDIATELY,
        });
      }
      lastErasePoint.current = null;
      return;
    }
    const here: [number, number] = [pointer.x, pointer.y];
    const from = lastErasePoint.current ?? here;
    lastErasePoint.current = here;
    const next = eraseAlong(api.getSceneElementsIncludingDeleted(), from, here, ERASER_SIZE / zoom.value);
    if (!next) return;
    next.forEach((el) => seenIds.current.add(el.id)); // pieces aren't "new lines" for cross-outs
    api.updateScene({ elements: next, captureUpdate: CaptureUpdateAction.EVENTUALLY });
  };

  // ---------- Changes ----------

  // Excalidraw calls this on every change (each stroke, typed letter, even mouse moves).
  const handleChange: OnChange = (elements, appState, files) => {
    const tool = appState.activeTool;
    const eraserNow = tool.type === 'custom' && tool.customType === STROKE_ERASER;
    if (eraserNow !== strokeEraserOn) setStrokeEraserOn(eraserNow);

    // Only look for cross-outs once a line is finished (not while it's being drawn).
    if (!appState.newElement && !appState.multiElement) checkForCrossOut(elements, appState);

    // Wait for a short pause, then save to the database.
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
    <div
      className={strokeEraserOn ? 'board-surface stroke-erasing' : 'board-surface'}
      ref={setContainer}
      onPointerLeave={() => setCursor(null)}
    >
      <Excalidraw
        initialData={initialData}
        excalidrawAPI={setApi}
        onChange={handleChange}
        onPointerUpdate={handlePointerUpdate}
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

      <StrokeEraserButton container={container} active={strokeEraserOn} onSelect={selectStrokeEraser} />

      {/* Circle that shows the stroke eraser's size */}
      {strokeEraserOn && cursor && (
        <div
          className="eraser-cursor"
          style={{ left: cursor.x, top: cursor.y, width: ERASER_SIZE * 2, height: ERASER_SIZE * 2 }}
        />
      )}

      {isFirstBoard && <UpcomingEvents ref={upcomingRef} events={events} />}
    </div>
  );
}
