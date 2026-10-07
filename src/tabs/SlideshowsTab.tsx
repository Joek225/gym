// Slideshows tab.
//   • The list: all your slideshows, with a preview of their first page. "+ New slideshow" makes one;
//     × deletes one.
//   • Inside a slideshow: the same drawing board as the Whiteboard tab, for the page you're on.
//     Top: ← back to the list, and the slideshow's title (click to edit).
//     Bottom: a strip with a preview of every page — click one to open it, + adds a page,
//     ▾ has "Duplicate page" and "Delete page".
import { useCallback, useEffect, useRef, useState } from 'react';
import { db, type SlideRecord, type SlideshowRecord } from '../db';
import BoardCanvas from '../whiteboard/BoardCanvas';
import { pagePreview, svgUrl } from '../slides/preview';

const newPage = (showId: string, order: number, data: unknown = null): SlideRecord => ({
  id: crypto.randomUUID(),
  showId,
  order,
  data,
  updatedAt: Date.now(),
});

export default function SlideshowsTab() {
  const [openId, setOpenId] = useState<string | null>(null);
  return openId ? (
    <SlideshowEditor showId={openId} onExit={() => setOpenId(null)} />
  ) : (
    <SlideshowList onOpen={setOpenId} />
  );
}

// ---------- The list of slideshows ----------
function SlideshowList({ onOpen }: { onOpen: (id: string) => void }) {
  const [shows, setShows] = useState<(SlideshowRecord & { pages: number; cover: string | null })[] | null>(null);

  const load = useCallback(async () => {
    const list = await db.slideshows.orderBy('updatedAt').reverse().toArray();
    const withInfo = await Promise.all(
      list.map(async (show) => {
        const pages = (await db.slides.where('showId').equals(show.id).sortBy('order')) as SlideRecord[];
        return { ...show, pages: pages.length, cover: pages[0] ? await pagePreview(pages[0].data) : null };
      }),
    );
    setShows(withInfo);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const create = async () => {
    const now = Date.now();
    const show = { id: crypto.randomUUID(), title: 'Untitled slideshow', createdAt: now, updatedAt: now };
    await db.slideshows.add(show);
    await db.slides.add(newPage(show.id, 0));
    onOpen(show.id);
  };

  const remove = async (id: string) => {
    await db.slides.where('showId').equals(id).delete();
    await db.slideshows.delete(id);
    load();
  };

  if (!shows) return <div className="placeholder">Loading…</div>;
  return (
    <div className="shows">
      <div className="shows-grid">
        <button className="show-card new" onClick={create}>
          <span className="show-thumb new-thumb">+</span>
          <span className="show-title">New slideshow</span>
        </button>
        {shows.map((s) => (
          <div key={s.id} className="show-card" onClick={() => onOpen(s.id)}>
            <span className="show-thumb">{s.cover && <img src={svgUrl(s.cover)} alt="" />}</span>
            <span className="show-title">{s.title}</span>
            <span className="show-sub">
              {s.pages} {s.pages === 1 ? 'page' : 'pages'}
            </span>
            <button
              className="show-x"
              title="Delete slideshow"
              onClick={(e) => {
                e.stopPropagation();
                remove(s.id);
              }}
            >
              ×
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

// ---------- One slideshow ----------
function SlideshowEditor({ showId, onExit }: { showId: string; onExit: () => void }) {
  const [show, setShow] = useState<SlideshowRecord | null>(null);
  const [pages, setPages] = useState<SlideRecord[]>([]);
  const [current, setCurrent] = useState<string | null>(null);
  const [previews, setPreviews] = useState<Record<string, string | null>>({});
  const [menuOpen, setMenuOpen] = useState(false);
  const stripRef = useRef<HTMLDivElement>(null);

  // Load the slideshow, its pages, and their previews.
  useEffect(() => {
    (async () => {
      const s = await db.slideshows.get(showId);
      const list = (await db.slides.where('showId').equals(showId).sortBy('order')) as SlideRecord[];
      setShow(s ?? null);
      setPages(list);
      setCurrent(list[0]?.id ?? null);
      const pics: Record<string, string | null> = {};
      for (const p of list) pics[p.id] = await pagePreview(p.data);
      setPreviews(pics);
    })();
  }, [showId]);

  const touch = () => db.slideshows.update(showId, { updatedAt: Date.now() });

  const rename = (title: string) => {
    setShow((s) => s && { ...s, title });
    db.slideshows.update(showId, { title: title.trim() || 'Untitled slideshow', updatedAt: Date.now() });
  };

  // Save the new page order (0, 1, 2, …) after adding/removing/duplicating.
  const saveOrder = async (list: SlideRecord[]) => {
    const renumbered = list.map((p, i) => ({ ...p, order: i }));
    await Promise.all(renumbered.map((p) => db.slides.update(p.id, { order: p.order })));
    setPages(renumbered);
    touch();
  };

  const addPage = async () => {
    const at = pages.findIndex((p) => p.id === current) + 1; // right after the page you're on
    const page = newPage(showId, at);
    await db.slides.add(page);
    const list = [...pages];
    list.splice(at, 0, page);
    await saveOrder(list);
    setCurrent(page.id);
    setTimeout(() => stripRef.current?.querySelector('.slide-thumb.active')?.scrollIntoView({ inline: 'nearest' }), 50);
  };

  const duplicatePage = async () => {
    setMenuOpen(false);
    const at = pages.findIndex((p) => p.id === current);
    const original = await db.slides.get(current!);
    const copy = newPage(showId, at + 1, original?.data ?? null);
    await db.slides.add(copy);
    const list = [...pages];
    list.splice(at + 1, 0, copy);
    await saveOrder(list);
    setPreviews((p) => ({ ...p, [copy.id]: p[current!] ?? null }));
    setCurrent(copy.id);
  };

  const deletePage = async () => {
    setMenuOpen(false);
    const at = pages.findIndex((p) => p.id === current);
    await db.slides.delete(current!);
    let list = pages.filter((p) => p.id !== current);
    if (list.length === 0) {
      const blank = newPage(showId, 0); // a slideshow always has at least one page
      await db.slides.add(blank);
      list = [blank];
    }
    await saveOrder(list);
    setCurrent(list[Math.min(at, list.length - 1)].id);
  };

  // After each save of the open page, refresh its preview (a moment later, to keep drawing smooth).
  const previewTimer = useRef<number | undefined>(undefined);
  const onSaved = (data: unknown) => {
    const id = current!;
    window.clearTimeout(previewTimer.current);
    previewTimer.current = window.setTimeout(async () => {
      const pic = await pagePreview(data);
      setPreviews((p) => ({ ...p, [id]: pic }));
    }, 300);
    touch();
  };

  if (!show || !current) return <div className="placeholder">Loading…</div>;

  return (
    <div className="whiteboard slideshow">
      <div className="board-bar show-bar">
        <button className="show-exit" onClick={onExit} title="Back to all slideshows">
          ←
        </button>
        <input
          className="show-title-input"
          value={show.title}
          onChange={(e) => rename(e.target.value)}
          onFocus={(e) => e.currentTarget.select()}
          onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
        />
      </div>

      <div className="board-canvas">
        {/* "key" builds a fresh board for each page */}
        <BoardCanvas key={current} boardId={current} isFirstBoard={false} store="slides" onSaved={onSaved} />
      </div>

      {/* Page previews along the bottom */}
      <div className="slide-strip" ref={stripRef}>
        {pages.map((p, i) => (
          <button
            key={p.id}
            className={p.id === current ? 'slide-thumb active' : 'slide-thumb'}
            onClick={() => setCurrent(p.id)}
          >
            {previews[p.id] && <img src={svgUrl(previews[p.id]!)} alt="" />}
            <span className="slide-num">{i + 1}</span>
          </button>
        ))}
        <div className="slide-add">
          <button onClick={addPage} title="Add a page">
            +
          </button>
          <button onClick={() => setMenuOpen(!menuOpen)} title="More">
            ▾
          </button>
          {menuOpen && (
            <div className="slide-menu">
              <button onClick={duplicatePage}>Duplicate page</button>
              <button onClick={deletePage}>Delete page</button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
