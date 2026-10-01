// A small month preview (shown in the row above the big calendar). Click it to open that month.
// Days with a workout are filled in red.
import { GYM_COLOR } from '../gym/workouts';
import { MONTH_NAMES, WEEKDAYS, dateKey, monthGrid, todayKey, type YearMonth } from './dates';

interface Props {
  ym: YearMonth;
  workoutDates: Set<string>;
  onOpen: () => void;
}

export default function MiniMonth({ ym, workoutDates, onOpen }: Props) {
  const today = todayKey();
  return (
    <button className="mini-month" onClick={onOpen} title="Open this month">
      <div className="mini-title">
        {MONTH_NAMES[ym.month].slice(0, 3)} {ym.year}
      </div>
      <div className="mini-grid">
        {WEEKDAYS.map((w) => (
          <span key={w} className="mini-weekday">
            {w[0]}
          </span>
        ))}
        {monthGrid(ym).map((d) => {
          const key = dateKey(d);
          const classes = ['mini-day'];
          if (d.getMonth() !== ym.month) classes.push('other-month');
          if (key === today) classes.push('today');
          const worked = workoutDates.has(key);
          return (
            <span key={key} className={classes.join(' ')} style={worked ? { background: GYM_COLOR } : undefined}>
              {d.getDate()}
            </span>
          );
        })}
      </div>
    </button>
  );
}
