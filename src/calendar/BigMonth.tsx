// The large month grid in the middle of the Calendar tab.
// Each day is a cell; later phases fill cells with category colors and events.
import { WEEKDAYS, dateKey, monthGrid, todayKey, type YearMonth } from './dates';

export default function BigMonth({ ym }: { ym: YearMonth }) {
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
        const classes = ['day-cell'];
        if (d.getMonth() !== ym.month) classes.push('other-month');
        if (key === today) classes.push('today');
        return (
          <div key={key} className={classes.join(' ')}>
            <span className="day-number">{d.getDate()}</span>
          </div>
        );
      })}
    </div>
  );
}
