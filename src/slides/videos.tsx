// Videos on slides.
// A video sits on the board as one of Excalidraw's "embeddable" boxes. You can move and resize it
// like a shape; click the middle of it to play.
//   • YouTube / Vimeo links: Excalidraw plays these itself.
//   • Video files from your computer: saved in the browser's database (the "videos" table), and the
//     box's link is "https://video.local/<id>". We draw a normal video player for those.
import { useEffect, useState } from 'react';
import { CaptureUpdateAction, convertToExcalidrawElements } from '@excalidraw/excalidraw';
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types';
import type { ExcalidrawElement, NonDeleted, ExcalidrawEmbeddableElement } from '@excalidraw/excalidraw/element/types';
import { db } from '../db';

const LOCAL_PREFIX = 'https://video.local/';
const VIDEO_WIDTH = 480; // how wide a new video is on the board

export const localVideoLink = (id: string) => LOCAL_PREFIX + id;
const localVideoId = (link: string | null) => (link?.startsWith(LOCAL_PREFIX) ? link.slice(LOCAL_PREFIX.length) : null);

// Tell Excalidraw our own video links are allowed. For anything else, its normal rules apply
// (YouTube, Vimeo, and a few other sites).
export const validateEmbeddable = (link: string) => (localVideoId(link) ? true : undefined);

// Draw our own player for uploaded videos; return null to let Excalidraw handle other links.
export function renderEmbeddable(element: NonDeleted<ExcalidrawEmbeddableElement>) {
  const id = localVideoId(element.link);
  return id ? <LocalVideo id={id} /> : null;
}

function LocalVideo({ id }: { id: string }) {
  const [src, setSrc] = useState<string | null | undefined>(undefined);
  useEffect(() => {
    let url: string | null = null;
    db.videos.get(id).then((v) => {
      url = v ? URL.createObjectURL(v.blob) : null;
      setSrc(url);
    });
    return () => {
      if (url) URL.revokeObjectURL(url);
    };
  }, [id]);
  if (src === undefined) return <div className="slide-video-msg">Loading video…</div>;
  if (src === null) return <div className="slide-video-msg">Video not found</div>;
  return <video className="slide-video" src={src} controls playsInline preload="metadata" />;
}

// Save a video file and return its link (plus its width ÷ height, so the box has the right shape).
export async function saveVideoFile(file: File): Promise<{ link: string; ratio: number }> {
  const id = crypto.randomUUID();
  await db.videos.add({ id, blob: file, name: file.name, createdAt: Date.now() });
  const ratio = await new Promise<number>((resolve) => {
    const v = document.createElement('video');
    const url = URL.createObjectURL(file);
    const done = (r: number) => {
      URL.revokeObjectURL(url);
      resolve(r);
    };
    v.onloadedmetadata = () => done(v.videoWidth && v.videoHeight ? v.videoWidth / v.videoHeight : 16 / 9);
    v.onerror = () => done(16 / 9);
    v.preload = 'metadata';
    v.src = url;
  });
  return { link: localVideoLink(id), ratio };
}

// Turn what you pasted into a link Excalidraw accepts, or null if it isn't a YouTube/Vimeo link.
export function cleanVideoLink(text: string): string | null {
  const t = text.trim();
  if (!t) return null;
  const url = /^https?:\/\//i.test(t) ? t : 'https://' + t;
  return /(youtube\.com|youtu\.be|vimeo\.com)\//i.test(url) ? url : null;
}

// Put a video box in the middle of what you're looking at, and select it.
export function insertVideo(api: ExcalidrawImperativeAPI, link: string, ratio = 16 / 9) {
  const s = api.getAppState();
  const zoom = s.zoom.value;
  const width = VIDEO_WIDTH;
  const height = Math.round(width / ratio);
  const cx = s.width / 2 / zoom - s.scrollX;
  const cy = s.height / 2 / zoom - s.scrollY;
  // Excalidraw can't build an embeddable directly, so build a plain box and turn it into one.
  const [box] = convertToExcalidrawElements([
    { type: 'rectangle', x: cx - width / 2, y: cy - height / 2, width, height },
  ]);
  const video = {
    ...box,
    type: 'embeddable',
    link,
    roundness: null,
    backgroundColor: 'transparent',
    strokeWidth: 1,
  } as unknown as ExcalidrawElement;
  api.updateScene({
    elements: [...api.getSceneElementsIncludingDeleted(), video],
    appState: { selectedElementIds: { [video.id]: true } },
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
}

// Every uploaded video a set of drawings uses (so we know which ones are still needed).
export function videoIdsIn(data: unknown): string[] {
  const elements = (data as { elements?: ExcalidrawElement[] } | null)?.elements ?? [];
  return elements.filter((e) => !e.isDeleted).flatMap((e) => localVideoId(e.link) ?? []);
}
