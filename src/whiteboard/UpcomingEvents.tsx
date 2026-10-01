// The to-do column on the right side of the To do list board, in three parts:
//   Reminders — every reminder you haven't crossed out
//   Upcoming  — events in the next 3 days (today, tomorrow, the day after)
//   Events    — events after that, up to a month ahead (so weekly ones don't fill the list)
// It's drawn on top of the board (clicks pass through), so a pencil line through a row
// crosses that event out (see BoardCanvas).
import { forwardRef, useImperativeHandle, useRef } from 'react';
import type { EventRecord } from '../db';
import { EVENT_COLOR, REMINDER_COLOR } from '../gym/workouts';
import { addDays, formatShortDate, formatTime, todayKey } from '../calendar/dates';

export interface UpcomingEventsHandle {
  // Where each event row is on screen, so a drawn line can be matched to a row.
  rowRects: () => { id: string; rect: DOMRect }[];
}

interface Props {
  events: EventRecord[];
  struckIds: string[]; // just crossed out: shown struck through while they fade away
  onRevert: () => void; // bring back every crossed-out event
  position: { left: number; top: number }; // where the column starts on the board
}

const UpcomingEvents = forwardRef<UpcomingEventsHandle, Props>(function UpcomingEvents(
  { events, struckIds, onRevert, position },
  ref,
) {
  const rows = useRef(new Map<string, HTMLElement>());

  const soonEnd = addDays(todayKey(), 2); // "Upcoming" = today through the day after tomorrow
  const monthEnd = addDays(todayKey(), 30);
  const reminders = events.filter((e) => e.kind === 'reminder');
  const others = events.filter((e) => e.kind !== 'reminder');
  const sections = [
    { title: 'Reminders', items: reminders },
    { title: 'Upcoming', items: others.filter((e) => e.date <= soonEnd) },
    { title: 'Events', items: others.filter((e) => e.date > soonEnd && e.date <= monthEnd) },
  ];

  useImperativeHandle(ref, () => ({
    rowRects: () =>
      events
        .map((e) => ({ id: e.id, el: rows.current.get(e.id) }))
        .filter((r): r is { id: string; el: HTMLElement } => !!r.el)
        .map((r) => ({ id: r.id, rect: r.el.getBoundingClientRect() })),
  }));

  return (
    <aside className="todo-column" style={{ left: position.left, top: position.top }}>
      <div className="todo-title">
        To do
        <button className="todo-revert" onClick={onRevert} title="Bring back everything you crossed out">
          ↺ Revert
        </button>
      </div>
      {events.length === 0 && <div className="todo-empty">Nothing coming up</div>}
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
