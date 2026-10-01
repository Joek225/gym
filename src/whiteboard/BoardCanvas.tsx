// One Excalidraw board. Loads its drawing from the database and auto-saves changes.
// Also adds the stroke eraser, our number hotkeys, and (on Board 1) the upcoming-events list.
import { useCallback, useEffect, useRef, useState } from 'react';
import { CaptureUpdateAction, Excalidraw, FONT_FAMILY, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import type {
  ExcalidrawImperativeAPI,
  ExcalidrawInitialDataState as InitialData,
} from '@excalidraw/excalidraw/types';
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types';
import { db, type EventRecord } from '../db';
import { timeSortKey, todayKey } from '../calendar/dates';
import { eraseAlong } from './strokeEraser';
import { STROKE_ERASER, StrokeEraserButton, useToolHotkeys } from './toolbar';
import UpcomingEvents, { type UpcomingEventsHandle } from './UpcomingEvents';
import CanvasButtons from './CanvasButtons';

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
  currentItemStrokeWidth: 1, // thin pen by default
};

// New text boxes are double-spaced (Excalidraw's own default is about 1.15).
const TEXT_LINE_HEIGHT = 2;

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

  // ---------- To do list (first board only) ----------
  // Upcoming calendar events fill the whole right side of the board, from the end of the
  // tool bar to the edge of the screen. You can't draw there: a line drawn there only
  // crosses out an event (and then disappears). Past events drop off by themselves.
  const [events, setEvents] = useState<EventRecord[]>([]);
  const [column, setColumn] = useState<{ left: number; top: number } | null>(null);
  const upcomingRef = useRef<UpcomingEventsHandle>(null);
  const [struckIds, setStruckIds] = useState<string[]>([]); // just crossed out (fading away)
  // The line you're drawing inside the to-do column. The column covers the board, so
  // Excalidraw's own line would be hidden there; we draw a copy on top so you can see it.
  const [strikePath, setStrikePath] = useState<[number, number][]>([]);
  const seenIds = useRef(new Set<string>()); // drawings that existed before (not new lines)
  const spacedIds = useRef(new Set<string>()); // new text boxes already made double-spaced

  const loadEvents = useCallback(async () => {
    const list = await db.events.where('date').aboveOrEqual(todayKey()).toArray(); // no past events
    setEvents(
      list
        .filter((e) => !e.struck)
        .sort((a, b) => (a.date + timeSortKey(a.time)).localeCompare(b.date + timeSortKey(b.time))),
    );
  }, []);

  useEffect(() => {
    if (isFirstBoard) loadEvents();
  }, [isFirstBoard, loadEvents]);

  // "Revert": un-cross every upcoming event, so the list matches the calendar again.
  const revertTodo = async () => {
    await db.events.where('date').aboveOrEqual(todayKey()).modify({ struck: false });
    loadEvents();
  };

  // Work out where the to-do column starts, and redo it when the window size changes.
  useEffect(() => {
    if (!isFirstBoard || !container) return;
    const measure = () => {
      const toolbar = container.querySelector('.App-toolbar');
      if (!toolbar) return;
      const box = container.getBoundingClientRect();
      const bar = toolbar.getBoundingClientRect();
      const roomOnRight = box.right - bar.right;
      setColumn(
        roomOnRight >= 220
          ? { left: bar.right - box.left + 16, top: 0 } // laptop: right of the tool bar
          : { left: box.width * 0.5, top: bar.bottom - box.top + 12 }, // phone: below it, right half
      );
    };
    measure();
    const resize = new ResizeObserver(measure);
    resize.observe(container);
    const later = window.setTimeout(measure, 300); // Excalidraw's toolbar may appear a moment later
    return () => {
      resize.disconnect();
      window.clearTimeout(later);
    };
  }, [isFirstBoard, container, initialData]);

  // When a drawing is finished, check whether it landed in the to-do column.
  // If it crosses out an event, hide that event. Either way, remove the drawing.
  const checkTodoColumn = (elements: readonly ExcalidrawElement[], appState: any) => {
    const newOnes = elements.filter((el) => !seenIds.current.has(el.id));
    newOnes.forEach((el) => seenIds.current.add(el.id));
    if (!isFirstBoard || !api || !column || !container) return;

    const box = container.getBoundingClientRect();
    const zoom = appState.zoom.value;
    const toScreenX = (x: number) => (x + appState.scrollX) * zoom;
    const toScreenY = (y: number) => (y + appState.scrollY) * zoom;
    const toRemove = new Set<string>();

    for (const el of newOnes as any[]) {
      if (el.isDeleted) continue;
      // The drawing's outline on screen (relative to the board).
      const pts: number[][] = el.points ?? [[0, 0], [el.width, el.height]];
      const xs = pts.map((p) => toScreenX(el.x + p[0]));
      const ys = pts.map((p) => toScreenY(el.y + p[1]));
      const left = Math.min(...xs);
      const right = Math.max(...xs);
      const top = Math.min(...ys);
      const bottom = Math.max(...ys);
      if (right < column.left || bottom < column.top) continue; // not in the column: keep it

      toRemove.add(el.id);
      if (!['freedraw', 'line', 'arrow'].includes(el.type)) continue;
      const middleY = (top + bottom) / 2;
      const hit = upcomingRef.current?.rowRects().find(({ id, rect }) => {
        const r = { left: rect.left - box.left, right: rect.right - box.left, top: rect.top - box.top, bottom: rect.bottom - box.top };
        const overlap = Math.min(right, r.right) - Math.max(left, r.left);
        return (
          !!id &&
          overlap > (r.right - r.left) * 0.3 && // covers a good part of the row's width
          middleY > r.top - 6 &&
          middleY < r.bottom + 6 && // goes through this row
          bottom - top < (r.bottom - r.top) * 2.5 // mostly sideways, not a big scribble
        );
      });
      if (hit) {
        db.events.update(hit.id, { struck: true });
        // Show the row crossed out for a moment, then remove it from the list.
        setStruckIds((ids) => [...ids, hit.id]);
        window.setTimeout(() => {
          setEvents((list) => list.filter((e) => e.id !== hit.id));
          setStruckIds((ids) => ids.filter((x) => x !== hit.id));
        }, 700);
      }
    }

    if (toRemove.size === 0) return;
    api.updateScene({
      elements: api
        .getSceneElementsIncludingDeleted()
        .map((x) => (toRemove.has(x.id) ? { ...x, isDeleted: true, version: x.version + 1 } : x)),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
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
    if (!api) return;

    // Drawing in the to-do column: keep a visible copy of the line on top of the column.
    if (isFirstBoard && column && !strokeEraserOn) {
      const st = api.getAppState();
      const drawing = ['freedraw', 'line', 'arrow'].includes(st.activeTool.type);
      const x = (pointer.x + st.scrollX) * st.zoom.value;
      const y = (pointer.y + st.scrollY) * st.zoom.value;
      if (drawing && button === 'down') {
        setStrikePath((path) => (path.length || (x >= column.left && y >= column.top) ? [...path, [x, y]] : path));
      } else if (strikePath.length) {
        window.setTimeout(() => setStrikePath([]), 250); // let it linger for a moment
      }
    }

    if (!strokeEraserOn) return;
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
    // A brand-new text box: make it double-spaced (once per text box).
    const editing = appState.editingTextElement as any;
    if (api && editing && !seenIds.current.has(editing.id) && !spacedIds.current.has(editing.id)) {
      spacedIds.current.add(editing.id);
      api.updateScene({
        elements: api
          .getSceneElementsIncludingDeleted()
          .map((el: any) => (el.id === editing.id ? { ...el, lineHeight: TEXT_LINE_HEIGHT } : el)),
        captureUpdate: CaptureUpdateAction.NEVER,
      });
    }

    const tool = appState.activeTool;
    const eraserNow = tool.type === 'custom' && tool.customType === STROKE_ERASER;
    if (eraserNow !== strokeEraserOn) setStrokeEraserOn(eraserNow);

    // Only check the to-do column once a drawing is finished (not while it's being drawn).
    if (!appState.newElement && !appState.multiElement && !appState.editingTextElement) {
      checkTodoColumn(elements, appState);
    }

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
      className={['board-surface', strokeEraserOn && 'stroke-erasing', isFirstBoard && 'todo-board']
        .filter(Boolean)
        .join(' ')}
      ref={setContainer}
      onPointerLeave={() => setCursor(null)}
    >
      <Excalidraw
        initialData={initialData}
        excalidrawAPI={setApi}
        onChange={handleChange}
        onPointerUpdate={handlePointerUpdate}
        theme="dark"
        aiEnabled={false}
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
      />

      {/* Clear-board and background buttons (instead of Excalidraw's ☰ menu) */}
      <CanvasButtons api={api} />

      <StrokeEraserButton container={container} active={strokeEraserOn} onSelect={selectStrokeEraser} />

      {/* Circle that shows the stroke eraser's size */}
      {strokeEraserOn && cursor && (
        <div
          className="eraser-cursor"
          style={{ left: cursor.x, top: cursor.y, width: ERASER_SIZE * 2, height: ERASER_SIZE * 2 }}
        />
      )}

      {isFirstBoard && column && (
        <UpcomingEvents
          ref={upcomingRef}
          events={events}
          struckIds={struckIds}
          onRevert={revertTodo}
          position={column}
        />
      )}

      {/* Your line while you cross something out (drawn above the to-do column) */}
      {strikePath.length > 1 && (
        <svg className="strike-preview">
          <polyline points={strikePath.map((p) => p.join(',')).join(' ')} />
        </svg>
      )}
    </div>
  );
}
