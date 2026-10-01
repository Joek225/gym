// A small month preview (shown in the row above the big calendar). Click it to open that month.
import { MONTH_NAMES, WEEKDAYS, dateKey, monthGrid, todayKey, type YearMonth } from './dates';

interface Props {
  ym: YearMonth;
  onOpen: () => void;
}

export default function MiniMonth({ ym, onOpen }: Props) {
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
          return (
            <span key={key} className={classes.join(' ')}>
              {d.getDate()}
            </span>
          );
        })}
      </div>
    </button>
  );
}
