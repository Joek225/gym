// The list of upcoming calendar events shown on the right side of Board 1.
// Past events disappear on their own; crossing one out with a line hides it (see BoardCanvas).
import { forwardRef, useImperativeHandle, useRef } from 'react';
import type { EventRecord } from '../db';
import { EVENT_COLOR } from '../gym/workouts';
import { formatShortDate, formatTime } from '../calendar/dates';

export interface UpcomingEventsHandle {
  // Where each event row is on screen, so a drawn line can be matched to a row.
  rowRects: () => { id: string; rect: DOMRect }[];
}

const UpcomingEvents = forwardRef<UpcomingEventsHandle, { events: EventRecord[] }>(
  function UpcomingEvents({ events }, ref) {
    const rows = useRef(new Map<string, HTMLElement>());

    useImperativeHandle(ref, () => ({
      rowRects: () =>
        events
          .map((e) => ({ id: e.id, el: rows.current.get(e.id) }))
          .filter((r): r is { id: string; el: HTMLElement } => !!r.el)
          .map((r) => ({ id: r.id, rect: r.el.getBoundingClientRect() })),
    }));

    if (events.length === 0) return null;
    return (
      <aside className="upcoming">
        <div className="upcoming-title">Upcoming</div>
        {events.map((e) => (
          <div
            key={e.id}
            className="upcoming-row"
            ref={(el) => {
              if (el) rows.current.set(e.id, el);
              else rows.current.delete(e.id);
            }}
          >
            <span className="event-dot" style={{ background: EVENT_COLOR }} />
            <span className="upcoming-text">
              {e.title} <span className="upcoming-date">{formatShortDate(e.date)}</span>
              {e.time && <b> {formatTime(e.time)}</b>}
            </span>
          </div>
        ))}
      </aside>
    );
  },
);

export default UpcomingEvents;
