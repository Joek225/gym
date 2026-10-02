// Calendar tab: 3 small previous months on top, then the big month with arrows and "Today".
// Clicking a day zooms into it (see DayZoom), which leads to the event and workout popups.
import { useCallback, useEffect, useState } from 'react';
import BigMonth from '../calendar/BigMonth';
import DayZoom from '../calendar/DayZoom';
import CardioEditor from '../calendar/CardioEditor';
import EventEditor from '../calendar/EventEditor';
import SpanEditor from '../calendar/SpanEditor';
import MiniMonth from '../calendar/MiniMonth';
import WorkoutEditor from '../calendar/WorkoutEditor';
import { MONTH_NAMES, addMonths, byDateAndTime, thisMonth } from '../calendar/dates';
import { db, type Cardio, type EventRecord, type SpanRecord, type WorkoutRecord } from '../db';
import { hasLifts, newWorkout, saveWorkout } from '../gym/workouts';

// What's open on top of the calendar right now.
type Popup =
  | { kind: 'none' }
  | { kind: 'zoom' }
  | { kind: 'event'; eventKind: 'event' | 'reminder'; event?: EventRecord }
  | { kind: 'workout'; workout: WorkoutRecord }
  | { kind: 'cardio' }
  | { kind: 'span'; start: string; end: string; span?: SpanRecord };


export default function CalendarTab() {
  // The month shown large. Starts at the current month.
  const [shown, setShown] = useState(thisMonth);
  const [eventsByDate, setEventsByDate] = useState(new Map<string, EventRecord[]>());
  const [workoutsByDate, setWorkoutsByDate] = useState(new Map<string, WorkoutRecord>());
  const [spans, setSpans] = useState<SpanRecord[]>([]);
  const [day, setDay] = useState<{ date: string; rect: DOMRect | null } | null>(null);
  const [popup, setPopup] = useState<Popup>({ kind: 'none' });

  // Load all events and workouts from the database, grouped by date.
  const reload = useCallback(async () => {
    const [events, workouts, allSpans] = await Promise.all([
      db.events.toArray(),
      db.workouts.toArray(),
      db.spans.orderBy('start').toArray(),
    ]);
    setSpans(allSpans);
    const byDate = new Map<string, EventRecord[]>();
    events
      .sort(byDateAndTime) // in time order (blocks at their real times)
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
  // Cardio from the cardio popup: save it into that day's workout (making one if needed).
  const saveCardio = async (cardio: Cardio | undefined) => {
    const date = day!.date;
    const w = (await db.workouts.get(date)) ?? (await newWorkout(date));
    await saveWorkout({ ...w, cardio });
    const saved = await db.workouts.get(date);
    setWorkoutsByDate((m) => {
      const next = new Map(m);
      if (saved) next.set(date, saved);
      else next.delete(date);
      return next;
    });
  };

  const openWorkout = async () => {
    const date = day!.date;
    const workout = workoutsByDate.get(date) ?? (await db.workouts.get(date)) ?? (await newWorkout(date));
    setPopup({ kind: 'workout', workout });
  };

  // The 3 months before the big one, oldest first (left → right).
  const previous = [3, 2, 1].map((n) => addMonths(shown, -n));
  // Small calendars: red only for days with lifts (cardio alone doesn't count).
  const workoutDates = new Set([...workoutsByDate.values()].filter(hasLifts).map((w) => w.date));

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
        <button className="today-btn" onClick={() => setShown(thisMonth())} title="Jump to this month">
          Jump
        </button>
      </div>

      <BigMonth
        ym={shown}
        eventsByDate={eventsByDate}
        workoutsByDate={workoutsByDate}
        spans={spans}
        onDayClick={(date, rect) => {
          setDay({ date, rect });
          setPopup({ kind: 'zoom' });
        }}
        onRangeSelected={(start, end) => setPopup({ kind: 'span', start, end })}
        onSpanClick={(span) => setPopup({ kind: 'span', start: span.start, end: span.end, span })}
      />

      {popup.kind === 'span' && (
        <SpanEditor start={popup.start} end={popup.end} span={popup.span} onClose={closeAll} />
      )}

      {day && popup.kind === 'zoom' && (
        <DayZoom
          date={day.date}
          from={day.rect}
          events={eventsByDate.get(day.date) ?? []}
          workout={workoutsByDate.get(day.date)}
          spans={spans.filter((sp) => sp.start <= day.date && day.date <= sp.end)}
          onCardio={() => setPopup({ kind: 'cardio' })}
          onAddEvent={(eventKind) => setPopup({ kind: 'event', eventKind })}
          onEditEvent={(event) => setPopup({ kind: 'event', eventKind: event.kind ?? 'event', event })}
          onWorkout={openWorkout}
          onClose={closeAll}
        />
      )}

      {day && popup.kind === 'event' && (
        <EventEditor
          date={day.date}
          kind={popup.eventKind}
          event={popup.event}
          onSaved={backToZoom}
          onClose={backToZoom}
        />
      )}

      {day && popup.kind === 'cardio' && (
        <CardioEditor
          date={day.date}
          cardio={workoutsByDate.get(day.date)?.cardio}
          onSave={async (c) => {
            await saveCardio(c);
            backToZoom();
          }}
          onClose={backToZoom}
        />
      )}

      {day && popup.kind === 'workout' && (
        <WorkoutEditor workout={popup.workout} onClose={backToZoom} />
      )}

    </div>
  );
}
