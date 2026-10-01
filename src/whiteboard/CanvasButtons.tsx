// The trash button, just to the left of the toolbar (separate from it). It clears the
// whole board, and Ctrl+Z / the undo arrow brings it back.
import { useEffect, useState } from 'react';
import { CaptureUpdateAction } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';

interface Props {
  api: ExcalidrawImperativeAPI | null;
  container: HTMLElement | null; // the board, used to find where the toolbar is
}

const SIZE = 36; // button size in pixels
const GAP = 8; // space between the button and the toolbar

export default function CanvasButtons({ api, container }: Props) {
  // Where to put the button: next to the toolbar's left end. (null = phone layout, see CSS)
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  useEffect(() => {
    if (!container) return;
    const measure = () => {
      const bar = container.querySelector('.App-toolbar')?.getBoundingClientRect();
      const box = container.getBoundingClientRect();
      if (!bar) return;
      const left = bar.left - box.left - SIZE - GAP;
      setPos(left > 8 ? { left, top: bar.top - box.top + (bar.height - SIZE) / 2 } : null);
    };
    measure();
    const resize = new ResizeObserver(measure);
    resize.observe(container);
    const later = window.setTimeout(measure, 300); // the toolbar may appear a moment later
    return () => {
      resize.disconnect();
      window.clearTimeout(later);
    };
  }, [container]);

  const clearBoard = () => {
    if (!api) return;
    api.updateScene({
      elements: api.getSceneElementsIncludingDeleted().map((el) =>
        el.isDeleted
          ? el
          : {
              ...el,
              isDeleted: true,
              version: el.version + 1,
              versionNonce: Math.floor(Math.random() * 2 ** 31),
              updated: Date.now(),
            },
      ),
      captureUpdate: CaptureUpdateAction.IMMEDIATELY, // so undo can bring it back
    });
    // Give the keyboard back to the board (so Ctrl+Z and the tool keys keep working).
    document.querySelector<HTMLElement>('.excalidraw')?.focus();
  };

  return (
    <div className={pos ? 'canvas-buttons' : 'canvas-buttons phone'} style={pos ?? undefined}>
      <button title="Clear the board (undo brings it back)" onClick={clearBoard}>
        <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.4">
          <path d="M3.5 5.5h13M8 5.5V3.5h4v2M5.5 5.5l.8 11h7.4l.8-11M8.5 8.5v5.5M11.5 8.5v5.5" />
        </svg>
      </button>
    </div>
  );
}
