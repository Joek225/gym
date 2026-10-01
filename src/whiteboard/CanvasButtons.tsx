// The two buttons in the board's top-left corner (they replace Excalidraw's ☰ menu):
//   🗑  clears the whole board (Ctrl+Z / the undo arrow brings it back)
//   BG  picks the board's background color
import { useState } from 'react';
import { CaptureUpdateAction } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';

// Background choices, as they should look on screen.
const BACKGROUNDS = ['#282a37', '#1b1c25', '#000000', '#1f2a3d', '#1f3329', '#3a2229', '#3a3a3a', '#f4f1ea'];

// Excalidraw's dark mode flips the board's colors (invert 93% + hue-rotate 180°).
// To make a color LOOK like `hex` on screen, we save the flipped version of it.
function forDarkMode(hex: string): string {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  // Undo hue-rotate(180°) (it's its own inverse)…
  const x = [
    -0.574 * r + 1.43 * g + 0.144 * b,
    0.426 * r + 0.43 * g + 0.144 * b,
    0.426 * r + 1.43 * g - 0.856 * b,
  ];
  // …then undo invert(93%).
  return (
    '#' +
    x
      .map((v) => Math.round(Math.min(1, Math.max(0, (0.93 - v) / 0.86)) * 255))
      .map((v) => v.toString(16).padStart(2, '0'))
      .join('')
  );
}

export default function CanvasButtons({ api }: { api: ExcalidrawImperativeAPI | null }) {
  const [pickerOpen, setPickerOpen] = useState(false);

  // Give the keyboard back to the board (so Ctrl+Z and the tool keys keep working).
  const refocusBoard = () => document.querySelector<HTMLElement>('.excalidraw')?.focus();

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
    refocusBoard();
  };

  const setBackground = (hex: string) => {
    api?.updateScene({
      appState: { viewBackgroundColor: forDarkMode(hex) },
      captureUpdate: CaptureUpdateAction.IMMEDIATELY,
    });
    setPickerOpen(false);
    refocusBoard();
  };

  return (
    <div className="canvas-buttons">
      <button title="Clear the board (undo brings it back)" onClick={clearBoard}>
        <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.4">
          <path d="M3.5 5.5h13M8 5.5V3.5h4v2M5.5 5.5l.8 11h7.4l.8-11M8.5 8.5v5.5M11.5 8.5v5.5" />
        </svg>
      </button>
      <button title="Background color" onClick={() => setPickerOpen(!pickerOpen)} className="bg-btn">
        BG
      </button>
      {pickerOpen && (
        <div className="bg-picker">
          {BACKGROUNDS.map((c) => (
            <button key={c} className="bg-swatch" style={{ background: c }} title={c} onClick={() => setBackground(c)} />
          ))}
          <label className="bg-custom" title="Any color">
            +
            <input type="color" onChange={(e) => setBackground(e.target.value)} />
          </label>
        </div>
      )}
    </div>
  );
}
