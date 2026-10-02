// Our own S / M / L / XL text-size buttons, shown in Excalidraw's style panel in place of
// its built-in ones. Sizes are shifted up one step: S 20, M 28, L 36, XL 48. New text starts at L.
// (A text box has one size for all its words — that's how Excalidraw works.)
import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { CaptureUpdateAction } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';

export const FONT_SIZES = [
  { label: 'S', size: 20 },
  { label: 'M', size: 28 },
  { label: 'L', size: 36 },
  { label: 'XL', size: 48 },
];
export const DEFAULT_FONT_SIZE = 36; // L

interface Props {
  container: HTMLElement | null;
  api: ExcalidrawImperativeAPI | null;
  current: number | null; // size of the selected text, or the size new text will use
}

export default function FontSizeButtons({ container, api, current }: Props) {
  const [slot, setSlot] = useState<HTMLElement | null>(null);

  // Put our buttons next to Excalidraw's (hidden) ones whenever the style panel shows them.
  useEffect(() => {
    if (!container) return;
    const host = document.createElement('div');
    const place = () => {
      const builtIn = container.querySelector('[data-testid="fontSize-small"]')?.closest('.buttonList');
      if (builtIn && builtIn.nextSibling !== host) builtIn.after(host);
      setSlot(builtIn ? host : null);
    };
    place();
    const observer = new MutationObserver(place);
    observer.observe(container, { childList: true, subtree: true });
    return () => {
      observer.disconnect();
      host.remove();
    };
  }, [container]);

  const choose = (size: number) => {
    if (!api) return;
    const state = api.getAppState();
    const selected = new Set(Object.keys(state.selectedElementIds));
    const editingId = (state.editingTextElement as any)?.id;
    api.updateScene({
      // Resize the selected text (or the text being typed); text grows in proportion.
      elements: api.getSceneElementsIncludingDeleted().map((el: any) => {
        if (el.type !== 'text' || el.isDeleted || !(selected.has(el.id) || el.id === editingId)) return el;
        const scale = size / el.fontSize;
        return {
          ...el,
          fontSize: size,
          width: el.width * scale,
          height: el.height * scale,
          version: el.version + 1,
          versionNonce: Math.floor(Math.random() * 2 ** 31),
        };
      }),
      appState: { currentItemFontSize: size }, // and new text uses this size
      captureUpdate: CaptureUpdateAction.IMMEDIATELY,
    });
  };

  if (!slot || !api) return null;
  return createPortal(
    <div className="buttonList">
      {FONT_SIZES.map(({ label, size }) => (
        <label key={label} className={current === size ? 'active' : ''} title={`${size}px`}>
          <input type="radio" checked={current === size} onChange={() => choose(size)} />
          <span className="text-option-label">{label}</span>
        </label>
      ))}
    </div>,
    slot,
  );
}
