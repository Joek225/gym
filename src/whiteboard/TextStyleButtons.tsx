// Our own text controls, shown in Excalidraw's style panel:
//   Font size: S / M / L / XL — shifted up one step from Excalidraw's (S 20, M 28, L 36, XL 48).
//   Style:     B (bold).
//   Spacing:   single or double line spacing.
// They change the selected text (or the text being typed), and what new text will look like.
// Note: a text box has one size and one style for all its words (that's how Excalidraw works).
import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { CaptureUpdateAction, FONT_FAMILY } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';

export const FONT_SIZES = [
  { label: 'S', size: 20 },
  { label: 'M', size: 28 },
  { label: 'L', size: 36 },
  { label: 'XL', size: 48 },
];
export const DEFAULT_FONT_SIZE = 36; // L

export const SINGLE = 1.25;
export const DOUBLE = 2;

// Excalidraw has no bold, so bold text uses a different font "slot" that styles.css points
// at Avenir's bold (see "Liberation Sans" there). Regular text uses the "Helvetica" slot.
export const REGULAR_FONT = FONT_FAMILY.Helvetica;
export const BOLD_FONT = FONT_FAMILY['Liberation Sans'];
const CSS_FAMILY: Record<number, string> = { [REGULAR_FONT]: 'Helvetica', [BOLD_FONT]: 'Liberation Sans' };

export interface TextStyle {
  size: number;
  bold: boolean;
  spacing: number; // line height, e.g. 1.25 or 2
}

// Work out a text box's width and height for its words, size, font and spacing.
const measureCanvas = document.createElement('canvas').getContext('2d')!;
export function measureText(text: string, fontSize: number, fontFamily: number, lineHeight: number) {
  measureCanvas.font = `${fontSize}px "${CSS_FAMILY[fontFamily] ?? 'Helvetica'}"`;
  const lines = text.split('\n');
  const width = Math.max(...lines.map((l) => measureCanvas.measureText(l).width));
  return { width: Math.ceil(width) + 1, height: Math.ceil(lines.length * fontSize * lineHeight) };
}

// Apply a change to the selected/edited text boxes, re-measuring them.
function restyle(api: ExcalidrawImperativeAPI, change: Partial<{ fontSize: number; fontFamily: number; lineHeight: number }>) {
  const state = api.getAppState();
  const selected = new Set(Object.keys(state.selectedElementIds));
  const editingId = (state.editingTextElement as any)?.id;
  api.updateScene({
    elements: api.getSceneElementsIncludingDeleted().map((el: any) => {
      if (el.type !== 'text' || el.isDeleted || el.containerId) return el;
      if (!(selected.has(el.id) || el.id === editingId)) return el;
      const next = { ...el, ...change };
      return {
        ...next,
        ...measureText(next.text, next.fontSize, next.fontFamily, next.lineHeight),
        version: el.version + 1,
        versionNonce: Math.floor(Math.random() * 2 ** 31),
      };
    }),
    appState: {
      ...(change.fontSize ? { currentItemFontSize: change.fontSize } : {}),
      ...(change.fontFamily ? { currentItemFontFamily: change.fontFamily } : {}),
    } as any,
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
}

interface Props {
  container: HTMLElement | null;
  api: ExcalidrawImperativeAPI | null;
  current: TextStyle; // style of the selected text, or what new text will use
  onSpacingDefault: (spacing: number) => void; // new text uses this spacing
}

export default function TextStyleButtons({ container, api, current, onSpacingDefault }: Props) {
  const [hosts, setHosts] = useState<{ size: HTMLElement; extra: HTMLElement } | null>(null);

  // Find Excalidraw's "Font size" section whenever the style panel shows it, and put our
  // size buttons inside it and our Style/Spacing sections right after it.
  useEffect(() => {
    if (!container) return;
    const size = document.createElement('div');
    const extra = document.createElement('div');
    extra.className = 'text-extra-slot';
    const place = () => {
      const builtIn = container.querySelector('[data-testid="fontSize-small"]')?.closest('.buttonList');
      const fieldset = builtIn?.closest('fieldset');
      if (builtIn && builtIn.nextSibling !== size) builtIn.after(size);
      if (fieldset && fieldset.nextSibling !== extra) fieldset.after(extra);
      setHosts(builtIn ? { size, extra } : null);
    };
    place();
    const observer = new MutationObserver(place);
    observer.observe(container, { childList: true, subtree: true });
    return () => {
      observer.disconnect();
      size.remove();
      extra.remove();
    };
  }, [container]);

  if (!hosts || !api) return null;

  const option = (key: string, label: string, active: boolean, onPick: () => void, title?: string) => (
    <label key={key} className={active ? 'active' : ''} title={title}>
      <input type="radio" checked={active} onChange={onPick} onClick={onPick} />
      <span className="text-option-label">{label}</span>
    </label>
  );

  return (
    <>
      {createPortal(
        <div className="buttonList">
          {FONT_SIZES.map(({ label, size }) =>
            option(label, label, current.size === size, () => restyle(api, { fontSize: size }), `${size}px`),
          )}
        </div>,
        hosts.size,
      )}
      {createPortal(
        <>
          <fieldset>
            <legend>Style</legend>
            <div className="buttonList">
              {option('bold', 'B', current.bold, () =>
                restyle(api, { fontFamily: current.bold ? REGULAR_FONT : BOLD_FONT }),
                'Bold',
              )}
            </div>
          </fieldset>
          <fieldset>
            <legend>Spacing</legend>
            <div className="buttonList">
              {option('single', 'Single', current.spacing === SINGLE, () => {
                onSpacingDefault(SINGLE);
                restyle(api, { lineHeight: SINGLE });
              })}
              {option('double', 'Double', current.spacing === DOUBLE, () => {
                onSpacingDefault(DOUBLE);
                restyle(api, { lineHeight: DOUBLE });
              })}
            </div>
          </fieldset>
        </>,
        hosts.extra,
      )}
    </>
  );
}
