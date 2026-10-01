// Toolbar changes for Excalidraw:
//  1) Number hotkeys 1–9 and 0 with no gaps (the diamond tool was removed).
//  2) A "Stroke eraser" button added to Excalidraw's toolbar, right after the normal eraser.
import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';

export const STROKE_ERASER = 'strokeEraser';

// Key → the tool it picks. Excalidraw's tool buttons have ids like "toolbar-ellipse".
const HOTKEYS: Record<string, string> = {
  '1': 'selection',
  '2': 'rectangle',
  '3': 'ellipse',
  '4': 'arrow',
  '5': 'line',
  '6': 'freedraw',
  '7': 'text',
  '8': 'image',
  '9': 'eraser',
  '0': STROKE_ERASER,
};
// Excalidraw shortcuts we turn off: diamond (D) and the hidden lock button (Q).
const BLOCKED_KEYS = ['d', 'q'];

function isTyping(target: EventTarget | null) {
  const el = target as HTMLElement | null;
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
}

/**
 * Listens for number keys before Excalidraw sees them and picks our tool instead.
 * `container` is the element around Excalidraw; `selectStrokeEraser` turns on our eraser.
 */
export function useToolHotkeys(container: HTMLElement | null, selectStrokeEraser: () => void) {
  useEffect(() => {
    if (!container) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.metaKey || e.altKey || isTyping(e.target)) return;
      const key = e.key.toLowerCase();
      const tool = HOTKEYS[key];
      if (!tool && !BLOCKED_KEYS.includes(key)) return;
      e.preventDefault();
      e.stopImmediatePropagation(); // Excalidraw never sees this key
      if (tool === STROKE_ERASER) selectStrokeEraser();
      else if (tool) container.querySelector<HTMLElement>(`[data-testid="toolbar-${tool}"]`)?.click();
    };
    // "capture: true" = we hear the key first, before Excalidraw does.
    window.addEventListener('keydown', onKeyDown, { capture: true });
    return () => window.removeEventListener('keydown', onKeyDown, { capture: true });
  }, [container, selectStrokeEraser]);
}

/**
 * Puts our stroke-eraser button into Excalidraw's own toolbar (right after its eraser),
 * and relabels the small hotkey numbers on each tool to match HOTKEYS.
 */
export function StrokeEraserButton({
  container,
  active,
  onSelect,
}: {
  container: HTMLElement | null;
  active: boolean;
  onSelect: () => void;
}) {
  const [slot, setSlot] = useState<HTMLElement | null>(null);

  useEffect(() => {
    if (!container) return;
    const host = document.createElement('span');
    host.className = 'stroke-eraser-slot';

    // Excalidraw redraws its toolbar sometimes (e.g. when the window is resized),
    // so keep checking that our button and the hotkey numbers are still in place.
    const place = () => {
      const eraser = container.querySelector('[data-testid="toolbar-eraser"]')?.closest('label');
      if (eraser && eraser.nextSibling !== host) eraser.after(host);
      for (const [key, tool] of Object.entries(HOTKEYS)) {
        const label = container
          .querySelector(`[data-testid="toolbar-${tool}"]`)
          ?.closest('label')
          ?.querySelector('.ToolIcon__keybinding');
        if (label && label.textContent !== key) label.textContent = key;
      }
    };
    place();
    setSlot(host);
    const observer = new MutationObserver(place);
    observer.observe(container, { childList: true, subtree: true });
    return () => {
      observer.disconnect();
      host.remove();
    };
  }, [container]);

  if (!slot) return null;
  return createPortal(
    <label className="ToolIcon Shape" title="Stroke eraser — rubs out part of a line — 0">
      <input
        type="radio"
        className="ToolIcon_type_radio ToolIcon_size_medium"
        name="stroke-eraser"
        checked={active}
        onChange={onSelect}
        onClick={onSelect}
        aria-label="Stroke eraser"
      />
      <div className="ToolIcon__icon" aria-hidden="true">
        {/* eraser with a dotted trail */}
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round">
          <path d="M9.5 15.5h6" strokeDasharray="1.5 2" />
          <path d="M4.2 11.3l6.6-6.6a1.4 1.4 0 0 1 2 0l2.5 2.5a1.4 1.4 0 0 1 0 2l-5.4 5.4H7.5l-3.3-3.3z" />
          <path d="M7.6 7.9l4.5 4.5" />
        </svg>
      </div>
      <span className="ToolIcon__keybinding">0</span>
    </label>,
    slot,
  );
}
