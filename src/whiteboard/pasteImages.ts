// Pasting pictures onto a board (Ctrl+V / Cmd+V).
// Excalidraw can paste pictures by itself, but only if you clicked on the board first AND the
// mouse is over the drawing area. So right after clicking a page thumbnail, the "+" button or
// a board's name, pasting did nothing. This handles picture pastes itself, whatever has focus.
// The picture lands where the mouse is (if it's over the board), otherwise in the middle.
import { useEffect } from 'react';
import { CaptureUpdateAction, convertToExcalidrawElements } from '@excalidraw/excalidraw';
import type { BinaryFileData, DataURL, ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';
import type { FileId } from '@excalidraw/excalidraw/element/types';

const MAX_SIDE = 1440; // big pictures are shrunk to this many pixels on their longest side
const MAX_SHOWN = 0.6; // a new picture covers at most 60% of the visible board

function isTyping(el: Element | null) {
  const h = el as HTMLElement | null;
  return !!h && (h.tagName === 'INPUT' || h.tagName === 'TEXTAREA' || h.isContentEditable);
}

const readAsDataURL = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result as string);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });

const loadImage = (src: string) =>
  new Promise<HTMLImageElement>((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = src;
  });

// The picture as a data URL (shrunk if it's huge), plus its size in pixels.
async function prepare(blob: Blob) {
  let dataURL = await readAsDataURL(blob);
  const img = await loadImage(dataURL);
  let w = img.naturalWidth || 400;
  let h = img.naturalHeight || 300;
  const scale = Math.min(1, MAX_SIDE / Math.max(w, h));
  if (scale < 1 && blob.type !== 'image/gif' && blob.type !== 'image/svg+xml') {
    w = Math.round(w * scale);
    h = Math.round(h * scale);
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    canvas.getContext('2d')!.drawImage(img, 0, 0, w, h);
    dataURL = blob.type === 'image/png' ? canvas.toDataURL('image/png') : canvas.toDataURL('image/jpeg', 0.9);
  }
  return { dataURL, w, h, mimeType: dataURL.slice(5, dataURL.indexOf(';')) };
}

async function insertPicture(
  api: ExcalidrawImperativeAPI,
  blob: Blob,
  at: { clientX: number; clientY: number } | null,
) {
  const { dataURL, w, h, mimeType } = await prepare(blob);
  const s = api.getAppState();
  const zoom = s.zoom.value;
  // Fit inside 60% of what you can see.
  const fit = Math.min(1, (s.width * MAX_SHOWN) / zoom / w, (s.height * MAX_SHOWN) / zoom / h);
  const width = w * fit;
  const height = h * fit;
  // Centre on the mouse, or on the middle of the view.
  const cx = at ? (at.clientX - s.offsetLeft) / zoom - s.scrollX : s.width / 2 / zoom - s.scrollX;
  const cy = at ? (at.clientY - s.offsetTop) / zoom - s.scrollY : s.height / 2 / zoom - s.scrollY;

  const fileId = crypto.randomUUID() as FileId;
  api.addFiles([{ id: fileId, dataURL: dataURL as DataURL, mimeType, created: Date.now() } as BinaryFileData]);
  const [picture] = convertToExcalidrawElements([
    { type: 'image', fileId, x: cx - width / 2, y: cy - height / 2, width, height },
  ]);
  api.updateScene({
    elements: [...api.getSceneElementsIncludingDeleted(), picture],
    appState: { selectedElementIds: { [picture.id]: true } },
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
}

// The picture in what was copied: an image file, or a lone <img> copied from a web page.
function findPicture(data: DataTransfer): Blob | string | null {
  const file = [...data.files].find((f) => f.type.startsWith('image/'));
  if (file) return file;
  const html = data.getData('text/html');
  if (!html) return null;
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const imgs = doc.querySelectorAll('img');
  const onlyPicture = imgs.length === 1 && !doc.body.textContent?.trim();
  return onlyPicture ? imgs[0].getAttribute('src') : null;
}

export function usePastePictures(api: ExcalidrawImperativeAPI | null, container: HTMLElement | null) {
  useEffect(() => {
    if (!api || !container) return;
    let mouse: { clientX: number; clientY: number } | null = null;

    const onMove = (e: PointerEvent) => {
      mouse = { clientX: e.clientX, clientY: e.clientY };
    };
    const onPaste = (e: ClipboardEvent) => {
      if (!e.clipboardData || isTyping(document.activeElement)) return; // pasting into a text box
      if (document.querySelector('.modal-backdrop')) return; // a popup is open
      const found = findPicture(e.clipboardData);
      if (!found) return; // not a picture: let Excalidraw handle it as usual
      e.preventDefault();
      e.stopImmediatePropagation(); // Excalidraw doesn't also paste it

      // Only use the mouse spot if the mouse is over the drawing area.
      const box = container.getBoundingClientRect();
      const over =
        mouse && mouse.clientX >= box.left && mouse.clientX <= box.right && mouse.clientY >= box.top && mouse.clientY <= box.bottom;
      const at = over && document.elementFromPoint(mouse!.clientX, mouse!.clientY) instanceof HTMLCanvasElement ? mouse : null;

      const blob =
        typeof found === 'string'
          ? fetch(found).then((r) => (r.ok ? r.blob() : Promise.reject(new Error('not found'))))
          : Promise.resolve(found);
      // Give the board the keyboard, so Delete / Ctrl+Z / arrow keys work on the new picture.
      container.querySelector<HTMLElement>('.excalidraw')?.focus();
      blob
        .then((b) => insertPicture(api, b, at))
        .catch(() => api.setToast({ message: "Couldn't paste that picture. Try saving it, then pasting the file." }));
    };

    document.addEventListener('pointermove', onMove, { passive: true });
    // "capture" = we see the paste before Excalidraw does.
    window.addEventListener('paste', onPaste, { capture: true });
    return () => {
      document.removeEventListener('pointermove', onMove);
      window.removeEventListener('paste', onPaste, { capture: true });
    };
  }, [api, container]);
}
