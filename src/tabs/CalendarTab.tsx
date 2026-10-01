// Calendar tab: 3 small previous months on top, then the big month with arrows and "Today".
// Clicking a day zooms into it (see DayZoom), which leads to the event and workout popups.
import { useCallback, useEffect, useState } from 'react';
import BigMonth from '../calendar/BigMonth';
import DayZoom from '../calendar/DayZoom';
import EventEditor from '../calendar/EventEditor';
import MiniMonth from '../calendar/MiniMonth';
import TemplatesEditor from '../calendar/TemplatesEditor';
import WorkoutEditor from '../calendar/WorkoutEditor';
import { MONTH_NAMES, addMonths, thisMonth } from '../calendar/dates';
import { db, type EventRecord, type WorkoutRecord } from '../db';
import { newWorkout } from '../gym/workouts';

// What's open on top of the calendar right now.
type Popup =
  | { kind: 'none' }
  | { kind: 'zoom' }
  | { kind: 'event'; event?: EventRecord }
  | { kind: 'workout'; workout: WorkoutRecord }
  | { kind: 'templates' };


export default function CalendarTab() {
  // The month shown large. Starts at the current month.
  const [shown, setShown] = useState(thisMonth);
  const [eventsByDate, setEventsByDate] = useState(new Map<string, EventRecord[]>());
  const [workoutsByDate, setWorkoutsByDate] = useState(new Map<string, WorkoutRecord>());
  const [day, setDay] = useState<{ date: string; rect: DOMRect | null } | null>(null);
  const [popup, setPopup] = useState<Popup>({ kind: 'none' });

  // Load all events and workouts from the database, grouped by date.
  const reload = useCallback(async () => {
    const [events, workouts] = await Promise.all([db.events.toArray(), db.workouts.toArray()]);
    const byDate = new Map<string, EventRecord[]>();
    events
      .sort((a, b) => (a.time || '99').localeCompare(b.time || '99')) // timed events first, in order
      .forEach((e) => byDate.set(e.date, [...(byDate.get(e.date) ?? []), e]));
    setEventsByDate(byDate);
    setWorkoutsByDate(new Map(workouts.map((w) => [w.date, w])));
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const closeAll = () => {
    setPopup({ kind: 'none' });
    setDay(null);
    reload();
  };
  // After saving/closing an event or workout, go back to the zoomed day (without re-zooming).
  const backToZoom = () => {
    setDay((d) => d && { ...d, rect: null });
    setPopup({ kind: 'zoom' });
    reload();
  };
  const openWorkout = async () => {
    const date = day!.date;
    const workout = workoutsByDate.get(date) ?? (await db.workouts.get(date)) ?? (await newWorkout(date));
    setPopup({ kind: 'workout', workout });
  };

  // The 3 months before the big one, oldest first (left → right).
  const previous = [3, 2, 1].map((n) => addMonths(shown, -n));
  const workoutDates = new Set(workoutsByDate.keys());

  return (
    <div className="calendar">
      <div className="mini-row">
        {previous.map((ym) => (
          <MiniMonth
            key={`${ym.year}-${ym.month}`}
            ym={ym}
            workoutDates={workoutDates}
            onOpen={() => setShown(ym)}
          />
        ))}
      </div>

      <div className="month-header">
        <button className="nav-btn" onClick={() => setShown(addMonths(shown, -1))} title="Previous month">
          ‹
        </button>
        <h2 className="month-title">
          {MONTH_NAMES[shown.month]} {shown.year}
        </h2>
        <button className="nav-btn" onClick={() => setShown(addMonths(shown, 1))} title="Next month">
          ›
        </button>
        <button className="today-btn" onClick={() => setShown(thisMonth())}>
          Today
        </button>
        <button className="today-btn templates-btn" onClick={() => setPopup({ kind: 'templates' })}>
          Workout templates
        </button>
      </div>

      <BigMonth
        ym={shown}
        eventsByDate={eventsByDate}
        workoutsByDate={workoutsByDate}
        onDayClick={(date, rect) => {
          setDay({ date, rect });
          setPopup({ kind: 'zoom' });
        }}
      />

      <button className="today-btn templates-btn-bottom" onClick={() => setPopup({ kind: 'templates' })}>
        Workout templates
      </button>

      {day && popup.kind === 'zoom' && (
        <DayZoom
          date={day.date}
          from={day.rect}
          events={eventsByDate.get(day.date) ?? []}
          workout={workoutsByDate.get(day.date)}
          onAddEvent={() => setPopup({ kind: 'event' })}
          onEditEvent={(event) => setPopup({ kind: 'event', event })}
          onWorkout={openWorkout}
          onClose={closeAll}
        />
      )}

      {day && popup.kind === 'event' && (
        <EventEditor
          date={day.date}
          event={popup.event}
          onSaved={backToZoom}
          onClose={backToZoom}
        />
      )}

      {day && popup.kind === 'workout' && (
        <WorkoutEditor workout={popup.workout} onClose={backToZoom} />
      )}

      {popup.kind === 'templates' && <TemplatesEditor onClose={() => setPopup({ kind: 'none' })} />}
    </div>
  );
}
