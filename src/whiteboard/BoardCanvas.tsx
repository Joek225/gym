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
import { byDateAndTime, todayKey } from '../calendar/dates';
import { eraseAlong } from './strokeEraser';
import { STROKE_ERASER, StrokeEraserButton, useToolHotkeys } from './toolbar';
import UpcomingEvents, { type UpcomingEventsHandle } from './UpcomingEvents';
import CanvasButtons from './CanvasButtons';
import FontSizeButtons, { DEFAULT_FONT_SIZE } from './FontSizeButtons';

// New text boxes are double-spaced (Excalidraw's own default is about 1.15).
const TEXT_LINE_HEIGHT = 2;

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
  currentItemFontSize: DEFAULT_FONT_SIZE, // new text starts at "L"
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

  // ---------- To do list (first board only) ----------
  // Upcoming calendar events fill the whole right side of the board, from the end of the
  // tool bar to the edge of the screen. You can't draw there: a line drawn there only
  // crosses out an event (and then disappears). Past events drop off by themselves.
  const [events, setEvents] = useState<EventRecord[]>([]);
  const [column, setColumn] = useState<{ left: number; top: number } | null>(null);
  const upcomingRef = useRef<UpcomingEventsHandle>(null);
  const todoScrollRef = useRef<HTMLElement>(null);
  const [struckIds, setStruckIds] = useState<string[]>([]); // just crossed out (fading away)
  // The line you're drawing inside the to-do column. The column covers the board, so
  // Excalidraw's own line would be hidden there; we draw a copy on top so you can see it.
  const [strikePath, setStrikePath] = useState<[number, number][]>([]);
  const strikePathRef = useRef<[number, number][]>([]);
  const seenIds = useRef(new Set<string>()); // drawings that existed before (not new lines)
  const spacedIds = useRef(new Set<string>()); // new text boxes already made double-spaced

  // What's on the list: every reminder you haven't crossed out (even past ones), plus
  // events from today on. Past events drop off by themselves.
  const loadEvents = useCallback(async () => {
    const today = todayKey();
    const list = await db.events.toArray();
    setEvents(
      list
        .filter((e) => !e.struck && (e.kind === 'reminder' || e.date >= today))
        .sort(byDateAndTime),
    );
  }, []);

  useEffect(() => {
    if (isFirstBoard) loadEvents();
  }, [isFirstBoard, loadEvents]);

  // "Revert": un-cross every reminder and upcoming event, so the list matches the calendar.
  const revertTodo = async () => {
    const today = todayKey();
    await db.events
      .filter((e) => e.kind === 'reminder' || e.date >= today)
      .modify({ struck: false });
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

  // Scrolling the to-do list: the column lets clicks through to the board (so you can cross
  // things out), so we catch the mouse wheel / trackpad here and scroll the list ourselves.
  useEffect(() => {
    if (!isFirstBoard || !container) return;
    const onWheel = (e: WheelEvent) => {
      const list = todoScrollRef.current;
      if (!list || e.ctrlKey) return; // ctrl+wheel = zoom, leave that to the board
      const r = list.getBoundingClientRect();
      if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) return;
      e.preventDefault();
      e.stopPropagation(); // don't also scroll the board
      list.scrollTop += e.deltaY;
    };
    container.addEventListener('wheel', onWheel, { capture: true, passive: false });
    return () => container.removeEventListener('wheel', onWheel, { capture: true });
  }, [isFirstBoard, container]);

  // The to-do list's box on the board (it's only as tall as the list itself).
  const todoRect = () => {
    const list = todoScrollRef.current;
    if (!list || !container) return null;
    const box = container.getBoundingClientRect();
    const r = list.getBoundingClientRect();
    return { left: r.left - box.left, right: r.right - box.left, top: r.top - box.top, bottom: r.bottom - box.top };
  };

  // When a drawing is finished, check whether it landed on the to-do list.
  // Anything drawn there is removed (the list stays clear). Below the list you can draw freely.
  const checkTodoColumn = (elements: readonly ExcalidrawElement[], appState: any) => {
    const newOnes = elements.filter((el) => !seenIds.current.has(el.id));
    newOnes.forEach((el) => seenIds.current.add(el.id));
    const area = isFirstBoard && api ? todoRect() : null;
    if (!area) return;

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
      const overlaps =
        Math.max(...xs) > area.left &&
        Math.min(...xs) < area.right &&
        Math.max(...ys) > area.top &&
        Math.min(...ys) < area.bottom;
      if (overlaps) toRemove.add(el.id);
    }

    if (toRemove.size === 0) return;
    api!.updateScene({
      elements: api!
        .getSceneElementsIncludingDeleted()
        .map((x) => (toRemove.has(x.id) ? { ...x, isDeleted: true, version: x.version + 1 } : x)),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
  };

  // Letting go of the mouse/finger ends a cross-out line.
  const finishStrike = () => {
    const path = strikePathRef.current;
    if (!path.length) return;
    strikePathRef.current = [];
    crossOut(path);
    window.setTimeout(() => setStrikePath([]), 250); // let the line linger for a moment
  };
  const finishStrikeRef = useRef(finishStrike);
  finishStrikeRef.current = finishStrike;
  useEffect(() => {
    const onUp = () => finishStrikeRef.current();
    window.addEventListener('pointerup', onUp);
    return () => window.removeEventListener('pointerup', onUp);
  }, []);

  // A line drawn across the to-do list (with any tool except the hand) crosses out the row it
  // goes through. It doesn't need to be straight or centered: the row whose middle is closest
  // to the line wins, as long as the line runs a fair way across it.
  const crossOut = (path: [number, number][]) => {
    const container_ = container;
    if (!container_ || path.length < 2) return;
    const box = container_.getBoundingClientRect();
    const xs = path.map((p) => p[0]);
    const ys = path.map((p) => p[1]);
    const left = Math.min(...xs);
    const right = Math.max(...xs);
    if (right - left < 30) return; // a click or a tiny wiggle
    if (Math.max(...ys) - Math.min(...ys) > 140) return; // a big scribble, not a cross-out

    let best: { id: string; dist: number } | null = null;
    for (const { id, rect } of upcomingRef.current?.rowRects() ?? []) {
      const r = { left: rect.left - box.left, right: rect.right - box.left, top: rect.top - box.top, bottom: rect.bottom - box.top };
      const overlap = Math.min(right, r.right) - Math.max(left, r.left);
      if (overlap < Math.min(40, (r.right - r.left) * 0.25)) continue;
      // Average height of the line where it passes over this row.
      const over = path.filter((p) => p[0] >= r.left && p[0] <= r.right);
      const avgY = over.reduce((sum, p) => sum + p[1], 0) / Math.max(over.length, 1);
      const dist = Math.abs(avgY - (r.top + r.bottom) / 2);
      if (dist > (r.bottom - r.top) / 2 + 16) continue; // too far above/below this row
      if (!best || dist < best.dist) best = { id, dist };
    }
    if (!best) return;
    const id = best.id;
    db.events.update(id, { struck: true });
    // Show the row crossed out for a moment, then remove it from the list.
    setStruckIds((ids) => [...ids, id]);
    window.setTimeout(() => {
      setEvents((list) => list.filter((e) => e.id !== id));
      setStruckIds((ids) => ids.filter((x) => x !== id));
    }, 700);
  };


  // ---------- Stroke eraser ----------
  const [strokeEraserOn, setStrokeEraserOn] = useState(false);
  // Spacing for new text boxes (double by default; the Spacing buttons change it).

  // What the text buttons show as picked: the selected text's style, or the new-text style.
  const [fontSizeNow, setFontSizeNow] = useState<number | null>(DEFAULT_FONT_SIZE);
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

    // Dragging across the to-do list: draw a visible copy of the line on top of the list,
    // and when you let go, cross out the row it went through.
    if (isFirstBoard && column && !strokeEraserOn && api.getAppState().activeTool.type !== 'hand') {
      const st = api.getAppState();
      const x = (pointer.x + st.scrollX) * st.zoom.value;
      const y = (pointer.y + st.scrollY) * st.zoom.value;
      const path = strikePathRef.current;
      if (button === 'down') {
        const area = todoRect();
        const startsOnList = !!area && x >= area.left && x <= area.right && y >= area.top && y <= area.bottom;
        if (path.length || startsOnList) {
          strikePathRef.current = [...path, [x, y]];
          setStrikePath(strikePathRef.current);
        }
      } else if (path.length) {
        finishStrike();
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

    // Which text size our S/M/L/XL buttons should show as picked.
    const selectedText = elements.find(
      (el) => el.type === 'text' && (appState.selectedElementIds[el.id] || el.id === editing?.id),
    ) as any;
    const sizeNow = selectedText ? selectedText.fontSize : appState.currentItemFontSize;
    if (sizeNow !== fontSizeNow) setFontSizeNow(sizeNow);

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

      {/* Clear-board button, just left of the toolbar */}
      <CanvasButtons api={api} container={container} />

      <FontSizeButtons container={container} api={api} current={fontSizeNow} />

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
          scrollRef={todoScrollRef}
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
