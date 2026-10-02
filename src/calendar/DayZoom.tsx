// The zoomed-in day: zooms out of the day you clicked. Four quarters:
//   Left, top (blue)         = events, in time order, notes underneath. Click one to edit it,
//                              or empty space to add one.
//   Left, bottom (dark blue) = reminders, the same way.
//   Right, top (red)         = the workout: its type and every logged line. Click to open the sheet.
//   Right, bottom (plum)     = cardio: what was logged. Click to open the cardio popup.
// After saving anything, you come back here.
import { useLayoutEffect, useRef } from 'react';
import type { EventRecord, SpanRecord, WorkoutRecord } from '../db';
import {
  CARDIO_COLOR,
  CARDIO_TEXT,
  EVENT_COLOR_DARK,
  GYM_COLOR_DARK,
  REMINDER_COLOR,
  formatCardio,
  formatLine,
  hasCardio,
  isLogged,
  workoutLabel,
} from '../gym/workouts';
import { formatLongDate, formatTime } from './dates';

interface Props {
  date: string;
  from: DOMRect | null; // where the clicked day cell was, so we can zoom out of it
  events: EventRecord[];
  workout?: WorkoutRecord;
  spans: SpanRecord[]; // multi-day labels covering this day (e.g. "Holiday")
  onCardio: () => void;
  onAddEvent: (kind: 'event' | 'reminder') => void;
  onEditEvent: (e: EventRecord) => void;
  onWorkout: () => void;
  onClose: () => void;
}

export default function DayZoom(props: Props) {
  const { date, from, events, workout } = props;
  const panel = useRef<HTMLDivElement>(null);

  // Zoom animation: start the panel exactly over the clicked cell, then grow to full size.
  // (Only the first time; coming back from an editor just shows it.)
  useLayoutEffect(() => {
    if (!from) return;
    const el = panel.current!;
    const to = el.getBoundingClientRect();
    const dx = from.left + from.width / 2 - (to.left + to.width / 2);
    const dy = from.top + from.height / 2 - (to.top + to.height / 2);
    el.style.transition = 'none';
    el.style.transform = `translate(${dx}px, ${dy}px) scale(${from.width / to.width}, ${from.height / to.height})`;
    el.getBoundingClientRect(); // make the browser apply the start position first
    el.style.transition = 'transform 220ms ease-out';
    el.style.transform = 'none';
  }, [from]);

  const lines = workout?.rows.filter(isLogged) ?? [];

  return (
    <div className="modal-backdrop zoom-backdrop" onMouseDown={(e) => e.target === e.currentTarget && props.onClose()}>
      <div className="day-zoom" ref={panel}>
        <div className="zoom-header">
          <span>{formatLongDate(date)}</span>
          <button className="close-btn" onClick={props.onClose} title="Close">
            ×
          </button>
        </div>

        <div className="zoom-halves">
          {/* Left side: events on top (blue), reminders below (dark blue) */}
          <div className="zoom-right">
            {(['event', 'reminder'] as const).map((kind) => (
              <div
                key={kind}
                className="zoom-half"
                style={{ background: kind === 'event' ? EVENT_COLOR_DARK : REMINDER_COLOR }}
                onClick={() => props.onAddEvent(kind)}
              >
                <div className="zoom-half-title">{kind === 'event' ? 'Events' : 'Reminders'}</div>
                {kind === 'event' &&
                  props.spans.map((sp) => (
                    <div key={sp.id} className="zoom-span">
                      {sp.label}
                    </div>
                  ))}
                {events
                  .filter((ev) => (ev.kind ?? 'event') === kind)
                  .map((ev) => (
                    <button
                      key={ev.id}
                      className="zoom-item"
                      onClick={(e) => {
                        e.stopPropagation(); // don't also trigger "add"
                        props.onEditEvent(ev);
                      }}
                    >
                      <span className="zoom-item-head">
                        <span className="zoom-item-title">{ev.title}</span>
                        {ev.time && <span>{formatTime(ev.time)}</span>}
                      </span>
                      {ev.notes && <span className="zoom-item-notes">{ev.notes}</span>}
                    </button>
                  ))}
                <span className="zoom-hint">{kind === 'event' ? '+ Add event' : '+ Add reminder'}</span>
              </div>
            ))}
          </div>

          {/* Right side: workout on top (red), cardio below (plum) */}
          <div className="zoom-right">
            <div className="zoom-half" style={{ background: GYM_COLOR_DARK }} onClick={props.onWorkout}>
              <div className="zoom-half-title">{workout && lines.length ? workoutLabel(workout) : 'Workout'}</div>
              {lines.map((r, i) => (
                <div key={i} className="zoom-lift">
                  {formatLine(r)}
                </div>
              ))}
              <span className="zoom-hint">{lines.length ? 'Edit workout' : '+ Log workout'}</span>
            </div>
            <div
              className="zoom-half"
              style={{ background: CARDIO_COLOR, color: CARDIO_TEXT }}
              onClick={props.onCardio}
            >
              <div className="zoom-half-title">Cardio</div>
              {workout?.cardio && hasCardio(workout.cardio) && (
                <>
                  <div className="zoom-lift">{formatCardio(workout.cardio)}</div>
                  {workout.cardio.weight && <div className="zoom-lift">weight {workout.cardio.weight}kg</div>}
                </>
              )}
              <span className="zoom-hint">{hasCardio(workout?.cardio) ? 'Edit cardio' : '+ Log cardio'}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
