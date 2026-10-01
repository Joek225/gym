// The trash button in the board's top-left corner (it replaces Excalidraw's ☰ menu):
// it clears the whole board, and Ctrl+Z / the undo arrow brings it back.
import { CaptureUpdateAction } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';

export default function CanvasButtons({ api }: { api: ExcalidrawImperativeAPI | null }) {
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
    <div className="canvas-buttons">
      <button title="Clear the board (undo brings it back)" onClick={clearBoard}>
        <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.4">
          <path d="M3.5 5.5h13M8 5.5V3.5h4v2M5.5 5.5l.8 11h7.4l.8-11M8.5 8.5v5.5M11.5 8.5v5.5" />
        </svg>
      </button>
    </div>
  );
}
