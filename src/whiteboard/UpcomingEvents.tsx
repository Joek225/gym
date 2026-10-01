// The to-do column on the right side of the To do list board, in two parts:
//   Reminders — every reminder you haven't crossed out
//   Upcoming  — events in the next 7 days (today and the 6 days after)
// It scrolls with the mouse wheel / trackpad when the list is long (see BoardCanvas).
// It's drawn on top of the board (clicks pass through), so a pencil line through a row
// crosses that event out (see BoardCanvas).
import { forwardRef, useImperativeHandle, useRef, type Ref } from 'react';
import type { EventRecord } from '../db';
import { EVENT_COLOR, REMINDER_COLOR } from '../gym/workouts';
import { addDays, formatShortDate, formatTime, todayKey } from '../calendar/dates';

export interface UpcomingEventsHandle {
  // Where each event row is on screen, so a drawn line can be matched to a row.
  rowRects: () => { id: string; rect: DOMRect }[];
}

interface Props {
  scrollRef?: Ref<HTMLElement>; // the scrolling part, so the board can scroll it
  events: EventRecord[];
  struckIds: string[]; // just crossed out: shown struck through while they fade away
  onRevert: () => void; // bring back every crossed-out event
  position: { left: number; top: number }; // where the column starts on the board
}

const UpcomingEvents = forwardRef<UpcomingEventsHandle, Props>(function UpcomingEvents(
  { events, struckIds, onRevert, position, scrollRef },
  ref,
) {
  const rows = useRef(new Map<string, HTMLElement>());

  const weekEnd = addDays(todayKey(), 6); // "Upcoming" = today through 6 days from now
  const reminders = events.filter((e) => e.kind === 'reminder');
  const others = events.filter((e) => e.kind !== 'reminder');
  const sections = [
    { title: 'Reminders', items: reminders },
    { title: 'Upcoming', items: others.filter((e) => e.date <= weekEnd) },
  ];

  useImperativeHandle(ref, () => ({
    rowRects: () =>
      events
        .map((e) => ({ id: e.id, el: rows.current.get(e.id) }))
        .filter((r): r is { id: string; el: HTMLElement } => !!r.el)
        .map((r) => ({ id: r.id, rect: r.el.getBoundingClientRect() })),
  }));

  return (
    <aside className="todo-column" ref={scrollRef} style={{ left: position.left, top: position.top }}>
      <div className="todo-title">
        To do
        <button className="todo-revert" onClick={onRevert} title="Bring back everything you crossed out">
          ↺ Revert
        </button>
      </div>
      {sections.every((s) => s.items.length === 0) && <div className="todo-empty">Nothing coming up</div>}
      {sections.map(
        ({ title, items }) =>
          items.length > 0 && (
            <section key={title} className="todo-section">
              <div className="todo-section-title">{title}</div>
              {items.map((e) => (
                <div
                  key={e.id}
                  className={struckIds.includes(e.id) ? 'todo-row struck' : 'todo-row'}
                  ref={(el) => {
                    if (el) rows.current.set(e.id, el);
                    else rows.current.delete(e.id);
                  }}
                >
                  <span
                    className="event-dot"
                    style={{ background: e.kind === 'reminder' ? REMINDER_COLOR : EVENT_COLOR }}
                  />
                  <span className="todo-text">
                    {e.title}
                    <span className="todo-date">
                      {' '}
                      {formatShortDate(e.date)}
                      {e.time && <span className="todo-time"> {formatTime(e.time)}</span>}
                    </span>
                  </span>
                </div>
              ))}
            </section>
          ),
      )}
    </aside>
  );
});

export default UpcomingEvents;
