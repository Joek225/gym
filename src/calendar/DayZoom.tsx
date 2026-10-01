// The zoomed-in day: zooms out of the day you clicked.
//   Left (blue)  = events: click an event to edit it, or empty space to add one.
//   Right (red)  = workout: click to open the workout sheet.
//   "Both"       = add an event first, then open the workout sheet.
import { useLayoutEffect, useRef } from 'react';
import type { EventRecord, WorkoutRecord } from '../db';
import { EVENT_COLOR, GYM_COLOR, workoutLabel } from '../gym/workouts';
import { formatLongDate, formatTime } from './dates';

interface Props {
  date: string;
  from: DOMRect; // where the clicked day cell was, so we can zoom out of it
  events: EventRecord[];
  workout?: WorkoutRecord;
  onAddEvent: () => void;
  onEditEvent: (e: EventRecord) => void;
  onWorkout: () => void;
  onBoth: () => void;
  onClose: () => void;
}

export default function DayZoom(props: Props) {
  const { date, from, events, workout } = props;
  const panel = useRef<HTMLDivElement>(null);

  // Zoom animation: start the panel exactly over the clicked cell, then grow to full size.
  useLayoutEffect(() => {
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

  const loggedSets = workout?.rows.filter((r) => r.reps || r.weight).length ?? 0;

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
          {/* Blue half: events */}
          <div className="zoom-half zoom-events" style={{ background: EVENT_COLOR }} onClick={props.onAddEvent}>
            {events.map((ev) => (
              <button
                key={ev.id}
                className="zoom-event"
                onClick={(e) => {
                  e.stopPropagation(); // don't also trigger "add event"
                  props.onEditEvent(ev);
                }}
              >
                <span className="event-dot dark-dot" />
                <span className="zoom-event-title">{ev.title}</span>
                {ev.time && <b>{formatTime(ev.time)}</b>}
              </button>
            ))}
            <span className="zoom-hint">+ Add event</span>
          </div>

          {/* Red half: workout */}
          <div className="zoom-half zoom-gym" style={{ background: GYM_COLOR }} onClick={props.onWorkout}>
            {workout ? (
              <>
                <span className="zoom-workout-label">{workoutLabel(workout)}</span>
                <span className="zoom-hint">
                  {loggedSets} {loggedSets === 1 ? 'line' : 'lines'} logged · tap to open
                </span>
              </>
            ) : (
              <span className="zoom-hint">+ Log workout</span>
            )}
          </div>
        </div>

        <button className="both-btn" onClick={props.onBoth}>
          Both
        </button>
      </div>
    </div>
  );
}
