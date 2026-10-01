// Calendar tab: 3 small previous months on top, then the big month with arrows and "Today".
import { useState } from 'react';
import BigMonth from '../calendar/BigMonth';
import MiniMonth from '../calendar/MiniMonth';
import { MONTH_NAMES, addMonths, thisMonth } from '../calendar/dates';

export default function CalendarTab() {
  // The month shown large. Starts at the current month.
  const [shown, setShown] = useState(thisMonth);

  // The 3 months before the big one, oldest first (left → right).
  const previous = [3, 2, 1].map((n) => addMonths(shown, -n));

  return (
    <div className="calendar">
      <div className="mini-row">
        {previous.map((ym) => (
          <MiniMonth key={`${ym.year}-${ym.month}`} ym={ym} onOpen={() => setShown(ym)} />
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
      </div>

      <BigMonth ym={shown} />
    </div>
  );
}
