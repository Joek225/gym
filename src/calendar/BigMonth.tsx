// The large month grid in the middle of the Calendar tab (Monday → Sunday).
// A day with a workout gets a red banner across its top fifth (UPPER / LOWER / custom name);
// its events are listed below with a blue dot, the title, and the time in bold.
import { useLayoutEffect, useRef, useState } from 'react';
import type { EventRecord, WorkoutRecord } from '../db';
import { EVENT_COLOR, GYM_COLOR, workoutLabel } from '../gym/workouts';
import { WEEKDAYS, dateKey, formatTime, monthGrid, todayKey, type YearMonth } from './dates';

const MAX_EVENTS_SHOWN = 3;

interface Props {
  ym: YearMonth;
  eventsByDate: Map<string, EventRecord[]>;
  workoutsByDate: Map<string, WorkoutRecord>;
  onDayClick: (date: string, cell: DOMRect) => void;
}

// Today's column gets wider ONLY when its entries don't fit on one line; it grows just
// enough to fit them (up to 40% of the calendar, after which the text wraps instead).
const TODAY_MAX_SHARE = 0.4;

export default function BigMonth({ ym, eventsByDate, workoutsByDate, onDayClick }: Props) {
  const today = todayKey();
  const grid = monthGrid(ym);
  const todayColumn = (new Date().getDay() + 6) % 7; // Monday = 0 … Sunday = 6
  const gridRef = useRef<HTMLDivElement>(null);
  const [todayWidth, setTodayWidth] = useState<number | null>(null); // null = normal width

  // Measure how wide today's entries are on a single line, and widen the column if needed.
  const todayEvents = eventsByDate.get(today);
  useLayoutEffect(() => {
    const measure = () => {
      const gridEl = gridRef.current;
      const cell = gridEl?.querySelector<HTMLElement>('.day-cell.today');
      if (!gridEl || !cell) return setTodayWidth(null);
      cell.classList.add('measuring'); // temporarily keep every entry on one line
      const lines = [...cell.querySelectorAll<HTMLElement>('.cell-event, .gym-banner')];
      const needed = Math.max(0, ...lines.map((el) => el.scrollWidth)) + 12; // + cell padding
      cell.classList.remove('measuring');
      const total = gridEl.clientWidth;
      const normal = total / 7;
      setTodayWidth(needed <= normal ? null : Math.min(needed, total * TODAY_MAX_SHARE));
    };
    measure();
    window.addEventListener('resize', measure);
    return () => window.removeEventListener('resize', measure);
  }, [ym, todayEvents, workoutsByDate]);

  const columns = WEEKDAYS.map((_, i) =>
    todayWidth && i === todayColumn ? `${todayWidth}px` : 'minmax(0, 1fr)',
  ).join(' ');
  const weeks = grid.length / 7;

  return (
    <div
      className="big-month"
      ref={gridRef}
      style={{ gridTemplateColumns: columns, gridTemplateRows: `auto repeat(${weeks}, minmax(var(--cell-min-h), 1fr))` }}
    >
      {WEEKDAYS.map((w) => (
        <div key={w} className="big-weekday">
          {w}
        </div>
      ))}
      {grid.map((d) => {
        const key = dateKey(d);
        const events = eventsByDate.get(key) ?? [];
        const workout = workoutsByDate.get(key);
        const classes = ['day-cell'];
        if (d.getMonth() !== ym.month) classes.push('other-month');
        if (key === today) classes.push('today');
        if (workout) classes.push('has-workout');
        return (
          <div
            key={key}
            className={classes.join(' ')}
            onClick={(e) => onDayClick(key, e.currentTarget.getBoundingClientRect())}
          >
            {workout && (
              <div className="gym-banner" style={{ background: GYM_COLOR }}>
                {workoutLabel(workout)}
              </div>
            )}
            <span className="day-number">{d.getDate()}</span>
            <div className="cell-events">
              {(key === today ? events : events.slice(0, MAX_EVENTS_SHOWN)).map((ev) => (
                <div key={ev.id} className="cell-event">
                  <span className="event-dot" style={{ background: EVENT_COLOR }} />
                  <span className="cell-event-title">{ev.title}</span>
                  {ev.time && <b className="cell-event-time">{formatTime(ev.time)}</b>}
                </div>
              ))}
              {key !== today && events.length > MAX_EVENTS_SHOWN && (
                <div className="cell-more">+{events.length - MAX_EVENTS_SHOWN} more</div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
