// The large month grid in the middle of the Calendar tab (Monday → Sunday).
// Each day cell, top to bottom:
//   • the top fifth: the date, and a red banner if lifts were logged (UPPER / LOWER / name)
//   • a pink CARDIO banner under it if cardio was logged
//   • blue bars for multi-day labels (e.g. "Holiday"), which run across the days they cover
//   • events: a blue dot, the title, and the time
// Click a day to zoom into it. Click and DRAG across several days to label them all.
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { EventRecord, SpanRecord, WorkoutRecord } from '../db';
import {
  CARDIO_COLOR,
  CARDIO_TEXT,
  EVENT_COLOR,
  EVENT_COLOR_DARK,
  REMINDER_COLOR,
  hasCardio,
  hasLifts,
  workoutColor,
  workoutLabel,
} from '../gym/workouts';
import { WEEKDAYS, dateKey, formatTime, monthGrid, todayKey, type YearMonth } from './dates';

// Reminder dots: the dark reminder blue, with a light ring so it shows on the dark calendar.
const REMINDER_DOT = REMINDER_COLOR;

// Today's column gets wider ONLY when its entries don't fit on one line; it grows just
// enough to fit them (up to 40% of the calendar, after which the text wraps instead).
const TODAY_MAX_SHARE = 0.4;

interface Props {
  ym: YearMonth;
  eventsByDate: Map<string, EventRecord[]>;
  workoutsByDate: Map<string, WorkoutRecord>;
  spans: SpanRecord[];
  onDayClick: (date: string, cell: DOMRect) => void;
  onRangeSelected: (start: string, end: string) => void; // after dragging across days
  onSpanClick: (span: SpanRecord) => void;
}

export default function BigMonth(props: Props) {
  const { ym, eventsByDate, workoutsByDate, spans } = props;
  const today = todayKey();
  const grid = monthGrid(ym);
  const todayColumn = (new Date().getDay() + 6) % 7; // Monday = 0 … Sunday = 6
  const gridRef = useRef<HTMLDivElement>(null);
  const [todayWidth, setTodayWidth] = useState<number | null>(null); // null = normal width

  // ---------- Today's column width ----------
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
      setTodayWidth(needed <= total / 7 ? null : Math.min(needed, total * TODAY_MAX_SHARE));
    };
    measure();
    window.addEventListener('resize', measure);
    return () => window.removeEventListener('resize', measure);
  }, [ym, todayEvents, workoutsByDate]);

  // ---------- Drag to select several days ----------
  const [drag, setDrag] = useState<{ from: string; to: string } | null>(null);
  const dragRef = useRef(drag);
  dragRef.current = drag;
  const skipClick = useRef(false); // the click right after a drag shouldn't open a day

  const dayUnder = (x: number, y: number) =>
    (document.elementFromPoint(x, y)?.closest('[data-date]') as HTMLElement | null)?.dataset.date;

  useEffect(() => {
    const finish = () => {
      const d = dragRef.current;
      if (!d) return;
      setDrag(null);
      if (d.from !== d.to) {
        skipClick.current = true;
        const [start, end] = [d.from, d.to].sort();
        props.onRangeSelected(start, end);
      }
    };
    const cancel = () => setDrag(null);
    window.addEventListener('pointerup', finish);
    window.addEventListener('pointercancel', cancel);
    return () => {
      window.removeEventListener('pointerup', finish);
      window.removeEventListener('pointercancel', cancel);
    };
  }, [props]);

  const [selStart, selEnd] = drag ? [drag.from, drag.to].sort() : ['', ''];

  // ---------- Layout ----------
  const columns = WEEKDAYS.map((_, i) =>
    todayWidth && i === todayColumn ? `${todayWidth}px` : 'minmax(0, 1fr)',
  ).join(' ');
  const weeks = grid.length / 7;

  return (
    <div
      className="big-month"
      ref={gridRef}
      style={{
        gridTemplateColumns: columns,
        // Each week is at least as tall as its busiest day (so every event shows),
        // and the weeks share any extra height to fill the screen.
        gridTemplateRows: `auto repeat(${weeks}, minmax(auto, 1fr))`,
      }}
      onPointerMove={(e) => {
        if (!drag) return;
        const date = dayUnder(e.clientX, e.clientY);
        if (date && date !== drag.to) setDrag({ ...drag, to: date });
      }}
    >
      {WEEKDAYS.map((w) => (
        <div key={w} className="big-weekday">
          {w}
        </div>
      ))}
      {grid.map((d, i) => {
        const key = dateKey(d);
        const events = eventsByDate.get(key) ?? [];
        const workout = workoutsByDate.get(key);
        const daySpans = spans.filter((sp) => sp.start <= key && key <= sp.end);
        const weekStart = i % 7 === 0;
        const classes = ['day-cell'];
        if (d.getMonth() !== ym.month) classes.push('other-month');
        if (key === today) classes.push('today');
        if (drag && selStart <= key && key <= selEnd) classes.push('selecting');
        return (
          <div
            key={key}
            data-date={key}
            className={classes.join(' ')}
            onPointerDown={(e) => {
              if (e.button === 0) setDrag({ from: key, to: key });
            }}
            onClick={(e) => {
              if (skipClick.current) {
                skipClick.current = false;
                return;
              }
              props.onDayClick(key, e.currentTarget.getBoundingClientRect());
            }}
          >
            {(() => {
              // The banners for this day, top to bottom. The date sits on the first one.
              const banners: { label: string; bg: string; fg: string }[] = [];
              if (workout && hasLifts(workout)) {
                banners.push({ label: workoutLabel(workout), bg: workoutColor(workout), fg: '#fff' });
              }
              if (workout && hasCardio(workout.cardio)) {
                banners.push({ label: 'CARDIO', bg: CARDIO_COLOR, fg: CARDIO_TEXT });
              }
              const [first, ...rest] = banners;
              return (
                <>
                  <div className="cell-top">
                    {first && (
                      <div className="gym-banner" style={{ background: first.bg, color: first.fg }}>
                        {first.label}
                      </div>
                    )}
                    <span
                      className={first ? 'day-number on-banner' : 'day-number'}
                      style={first ? { color: first.fg } : undefined}
                    >
                      {d.getDate()}
                    </span>
                  </div>
                  {rest.map((b) => (
                    <div key={b.label} className="cell-top">
                      <div className="gym-banner" style={{ background: b.bg, color: b.fg }}>
                        {b.label}
                      </div>
                    </div>
                  ))}
                </>
              );
            })()}

            {daySpans.map((sp) => (
              <div
                key={sp.id}
                className={[
                  'span-bar',
                  sp.start === key && 'span-start',
                  sp.end === key && 'span-end',
                ]
                  .filter(Boolean)
                  .join(' ')}
                style={{ background: EVENT_COLOR_DARK }}
                title={sp.label}
                onPointerDown={(e) => e.stopPropagation()} // clicking a bar edits it, not a drag
                onClick={(e) => {
                  e.stopPropagation();
                  props.onSpanClick(sp);
                }}
              >
                {/* The label is written at the start, and again at the start of each week. */}
                {(sp.start === key || weekStart) && sp.label}
              </div>
            ))}

            <div className="cell-events">
              {events.map((ev) => (
                <div key={ev.id} className="cell-event">
                  <span
                    className="event-dot"
                    style={{ background: ev.kind === 'reminder' ? REMINDER_DOT : EVENT_COLOR }}
                  />
                  <span className="cell-event-title">{ev.title}</span>
                  {ev.time && <span className="cell-event-time">{formatTime(ev.time)}</span>}
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}
