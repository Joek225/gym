// Right-click a text box that has math in it (like "12*3 + 4") to fill in the answer:
// a small menu offers "Fill in answer = 40", and the line becomes "12*3 + 4 = 40".
// Works line by line, so a text box with several sums gets every answer. Signs: + - * /
// (and brackets). Running it again after changing the numbers updates the answers.
import { useEffect, useState } from 'react';
import { CaptureUpdateAction, FONT_FAMILY } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';
import type { ExcalidrawElement, ExcalidrawTextElement } from '@excalidraw/excalidraw/element/types';

// ---------- The calculator ----------
// Reads "12*3 + 4" → 40. Returns null if it isn't a sum we can work out.
export function calculate(expr: string): number | null {
  const tokens = expr.match(/\d*\.\d+|\d+|[-+*/()]/g);
  if (!tokens || tokens.join('') !== expr.replace(/\s+/g, '')) return null; // something else in there
  let i = 0;
  const peek = () => tokens[i];
  // sum := product (("+" | "-") product)*
  const sum = (): number => {
    let v = product();
    while (peek() === '+' || peek() === '-') v = tokens[i++] === '+' ? v + product() : v - product();
    return v;
  };
  // product := factor (("*" | "/") factor)*
  const product = (): number => {
    let v = factor();
    while (peek() === '*' || peek() === '/') v = tokens[i++] === '*' ? v * factor() : v / factor();
    return v;
  };
  // factor := "-" factor | "(" sum ")" | number
  const factor = (): number => {
    const t = tokens[i++];
    if (t === '-') return -factor();
    if (t === '+') return factor();
    if (t === '(') {
      const v = sum();
      if (tokens[i++] !== ')') throw new Error('missing )');
      return v;
    }
    if (t !== undefined && /^[\d.]+$/.test(t)) return parseFloat(t);
    throw new Error('bad');
  };
  try {
    const v = sum();
    return i === tokens.length && Number.isFinite(v) ? v : null;
  } catch {
    return null;
  }
}

// How wide a text box needs to be for these lines, in the box's own font and size.
const FONT_NAMES = Object.fromEntries(Object.entries(FONT_FAMILY).map(([name, id]) => [id, name]));
let measurer: CanvasRenderingContext2D | null = null;
function textWidth(text: string, el: ExcalidrawTextElement): number {
  measurer ??= document.createElement('canvas').getContext('2d');
  if (!measurer) return el.width;
  measurer.font = `${el.fontSize}px "${FONT_NAMES[el.fontFamily] ?? 'Helvetica'}", sans-serif`;
  return Math.max(...text.split('\n').map((line) => measurer!.measureText(line).width));
}

const formatNumber = (n: number) => String(Math.round(n * 1e6) / 1e6);

// One line → the line with its answer, or null if the line isn't a sum.
// "12*3+4", "12*3+4 =" and "12*3+4 = 99" (an old answer) all become "12*3+4 = 40".
function fillLine(line: string): string | null {
  const question = line.replace(/\s*=.*$/, '');
  if (!/\d\s*[-+*/]\s*[-(\d.]/.test(question)) return null; // needs at least one sign between numbers
  const answer = calculate(question.trim());
  return answer === null ? null : `${question.trimEnd()} = ${formatNumber(answer)}`;
}

// The whole text with answers filled in, and the answers (for the menu), or null if no sums.
function fillText(text: string): { text: string; answers: string[] } | null {
  const answers: string[] = [];
  const lines = text.split('\n').map((line) => {
    const filled = fillLine(line);
    if (filled === null) return line;
    answers.push(filled.slice(filled.lastIndexOf('= ') + 2));
    return filled;
  });
  return answers.length ? { text: lines.join('\n'), answers } : null;
}

// ---------- Right-click on the board ----------
interface Menu {
  x: number; // where to show it (inside the board)
  y: number;
  element: ExcalidrawTextElement;
  text: string; // the new text
  answers: string[];
}

export function MathFill({ api, container }: { api: ExcalidrawImperativeAPI | null; container: HTMLElement | null }) {
  const [menu, setMenu] = useState<Menu | null>(null);

  useEffect(() => {
    if (!api || !container) return;
    const onContextMenu = (e: MouseEvent) => {
      if (!(e.target instanceof HTMLCanvasElement)) return; // e.g. right-click while typing
      const s = api.getAppState();
      const zoom = s.zoom.value;
      const x = (e.clientX - s.offsetLeft) / zoom - s.scrollX;
      const y = (e.clientY - s.offsetTop) / zoom - s.scrollY;
      const pad = 6 / zoom;
      // The top-most text box under the mouse.
      const hit = ([...api.getSceneElements()] as ExcalidrawElement[])
        .reverse()
        .find(
          (el): el is ExcalidrawTextElement =>
            el.type === 'text' && x >= el.x - pad && x <= el.x + el.width + pad && y >= el.y - pad && y <= el.y + el.height + pad,
        );
      const filled = hit && fillText(hit.originalText ?? hit.text);
      if (!hit || !filled) return; // not math: Excalidraw's own menu opens as usual
      e.preventDefault();
      e.stopImmediatePropagation(); // our menu instead of Excalidraw's
      const box = container.getBoundingClientRect();
      setMenu({ x: e.clientX - box.left, y: e.clientY - box.top, element: hit, ...filled });
    };
    container.addEventListener('contextmenu', onContextMenu, { capture: true });
    return () => container.removeEventListener('contextmenu', onContextMenu, { capture: true });
  }, [api, container]);

  // Close the menu on any click elsewhere, Escape, or scrolling.
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('pointerdown', close);
    window.addEventListener('wheel', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('pointerdown', close);
      window.removeEventListener('wheel', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [menu]);

  const fill = () => {
    if (!api || !menu) return;
    const current = api.getSceneElementsIncludingDeleted().find((el) => el.id === menu.element.id);
    if (current && current.type === 'text') {
      // Widen the box so the longer lines fit (text inside a shape keeps the shape's width).
      const old = current as ExcalidrawTextElement;
      const width = old.containerId ? old.width : Math.max(old.width, Math.ceil(textWidth(menu.text, old)));
      const changed = {
        ...old,
        text: menu.text,
        originalText: menu.text,
        width,
        version: old.version + 1,
        versionNonce: Math.floor(Math.random() * 2 ** 31),
        updated: Date.now(),
      };
      api.updateScene({
        elements: api.getSceneElementsIncludingDeleted().map((el) => (el.id === old.id ? (changed as ExcalidrawElement) : el)),
        captureUpdate: CaptureUpdateAction.IMMEDIATELY,
      });
    }
    setMenu(null);
  };

  if (!menu) return null;
  return (
    <div
      className="math-menu"
      style={{ left: menu.x, top: menu.y }}
      onPointerDown={(e) => e.stopPropagation()} // clicking the menu doesn't close it first
    >
      <button onClick={fill}>
        Fill in {menu.answers.length > 1 ? 'answers' : 'answer'}: = {menu.answers.join(', ')}
      </button>
    </div>
  );
}
