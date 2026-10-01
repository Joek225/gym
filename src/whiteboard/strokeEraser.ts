// The "stroke eraser": instead of deleting a whole drawing, it rubs out only the part of
// a pencil line under the eraser, splitting the line into pieces if needed.
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types';

type Point = [number, number];

// Distance from point p to the line segment a→b.
function distToSegment(p: Point, a: Point, b: Point): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const lenSq = dx * dx + dy * dy;
  let t = lenSq === 0 ? 0 : ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / lenSq;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

const randomInt = () => Math.floor(Math.random() * 2 ** 31);

// Pencil line points are stored relative to the element and may be rotated.
// This returns them as absolute positions on the board.
function absolutePoints(el: any): { points: Point[]; pressures: number[] } {
  const pts: Point[] = el.points;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const cx = el.x + (Math.min(...xs) + Math.max(...xs)) / 2;
  const cy = el.y + (Math.min(...ys) + Math.max(...ys)) / 2;
  const cos = Math.cos(el.angle);
  const sin = Math.sin(el.angle);
  const points = pts.map(([px, py]): Point => {
    const x = el.x + px - cx;
    const y = el.y + py - cy;
    return [cx + x * cos - y * sin, cy + x * sin + y * cos];
  });
  const pressures = el.pressures?.length === pts.length ? el.pressures : pts.map(() => 0.5);
  return { points, pressures };
}

// Add in-between points so no gap is bigger than `step` (so the eraser can't skip over a gap).
function densify(points: Point[], pressures: number[], step: number) {
  const outPts: Point[] = [points[0]];
  const outPr: number[] = [pressures[0]];
  for (let i = 1; i < points.length; i++) {
    const [ax, ay] = points[i - 1];
    const [bx, by] = points[i];
    const n = Math.ceil(Math.hypot(bx - ax, by - ay) / step);
    for (let k = 1; k <= n; k++) {
      const t = k / n;
      outPts.push([ax + (bx - ax) * t, ay + (by - ay) * t]);
      outPr.push(pressures[i - 1] + (pressures[i] - pressures[i - 1]) * t);
    }
  }
  return { points: outPts, pressures: outPr };
}

// Make a new pencil line from a run of absolute points, copying the look of `el`.
function pieceFrom(el: any, points: Point[], pressures: number[]): ExcalidrawElement {
  const [x0, y0] = points[0];
  const rel = points.map(([x, y]): Point => [x - x0, y - y0]);
  const xs = rel.map((p) => p[0]);
  const ys = rel.map((p) => p[1]);
  return {
    ...el,
    id: crypto.randomUUID(),
    seed: randomInt(),
    version: 1,
    versionNonce: randomInt(),
    updated: Date.now(),
    x: x0,
    y: y0,
    angle: 0,
    points: rel,
    pressures,
    width: Math.max(...xs) - Math.min(...xs),
    height: Math.max(...ys) - Math.min(...ys),
    lastCommittedPoint: null,
    boundElements: null,
  };
}

/**
 * Rub out everything within `radius` of the eraser's path (from → to).
 * Returns the new list of elements, or null if nothing was touched.
 */
export function eraseAlong(
  elements: readonly ExcalidrawElement[],
  from: Point,
  to: Point,
  radius: number,
): ExcalidrawElement[] | null {
  let changed = false;
  const result: ExcalidrawElement[] = [];

  for (const el of elements as any[]) {
    if (el.isDeleted || el.locked || el.type !== 'freedraw' || el.points.length === 0) {
      result.push(el);
      continue;
    }
    const abs = absolutePoints(el);
    const reach = radius + el.strokeWidth; // thicker lines are easier to hit

    // Quick check: skip lines that are nowhere near the eraser.
    const xs = abs.points.map((p) => p[0]);
    const ys = abs.points.map((p) => p[1]);
    if (
      Math.max(from[0], to[0]) < Math.min(...xs) - reach ||
      Math.min(from[0], to[0]) > Math.max(...xs) + reach ||
      Math.max(from[1], to[1]) < Math.min(...ys) - reach ||
      Math.min(from[1], to[1]) > Math.max(...ys) + reach
    ) {
      result.push(el);
      continue;
    }

    const dense = densify(abs.points, abs.pressures, Math.max(radius / 3, 0.5));
    const keep = dense.points.map((p) => distToSegment(p, from, to) > reach);
    if (keep.every(Boolean)) {
      result.push(el);
      continue;
    }

    // Split what's left into separate pieces wherever the eraser cut through.
    changed = true;
    let runPts: Point[] = [];
    let runPr: number[] = [];
    const flush = () => {
      if (runPts.length >= 2) result.push(pieceFrom(el, runPts, runPr));
      runPts = [];
      runPr = [];
    };
    dense.points.forEach((p, i) => {
      if (keep[i]) {
        runPts.push(p);
        runPr.push(dense.pressures[i]);
      } else flush();
    });
    flush();
    // Mark the original line as deleted (so undo can bring it back).
    result.push({ ...el, isDeleted: true, version: el.version + 1, versionNonce: randomInt() });
  }

  return changed ? result : null;
}
