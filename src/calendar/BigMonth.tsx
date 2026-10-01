// The large month grid in the middle of the Calendar tab (Monday → Sunday).
// A day with a workout gets a red banner across its top fifth (UPPER / LOWER / custom name);
// its events are listed below with a blue dot, the title, and the time in bold.
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

export default function BigMonth({ ym, eventsByDate, workoutsByDate, onDayClick }: Props) {
  const today = todayKey();
  return (
    <div className="big-month">
      {WEEKDAYS.map((w) => (
        <div key={w} className="big-weekday">
          {w}
        </div>
      ))}
      {monthGrid(ym).map((d) => {
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
              {events.slice(0, MAX_EVENTS_SHOWN).map((ev) => (
                <div key={ev.id} className="cell-event">
                  <span className="event-dot" style={{ background: EVENT_COLOR }} />
                  <span className="cell-event-title">{ev.title}</span>
                  {ev.time && <b className="cell-event-time">{formatTime(ev.time)}</b>}
                </div>
              ))}
              {events.length > MAX_EVENTS_SHOWN && (
                <div className="cell-more">+{events.length - MAX_EVENTS_SHOWN} more</div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
