// Progress tab: one graph per exercise, Upper day exercises first, then Lower.
// Each graph shows how that lift changed over time. The toggle at the top switches every
// graph between the heaviest weight of the day and the day's total volume (weight × reps).
// Hover a point to see that day's numbers.
import { useEffect, useState } from 'react';
import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { db } from '../db';
import { liftHistories, type LiftHistory, type LiftPoint } from '../gym/progress';

type Measure = 'heaviest' | 'volume';
const MEASURES: { id: Measure; label: string }[] = [
  { id: 'heaviest', label: 'Heaviest weight' },
  { id: 'volume', label: 'Total volume' },
];

// Lighter version of the gym red, readable on the dark cards (checked for contrast).
const LINE_COLOR = '#C76B7E';
const CARD = '#21232e';

const shortDate = (time: number) =>
  new Date(time).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
const kg = (n: number) => `${Math.round(n * 10) / 10}kg`;

export default function ProgressTab() {
  const [histories, setHistories] = useState<LiftHistory[] | null>(null);
  const [measure, setMeasure] = useState<Measure>('heaviest');

  useEffect(() => {
    db.workouts.toArray().then((all) => setHistories(liftHistories(all)));
  }, []);

  if (!histories) return <div className="placeholder">Loading…</div>;

  return (
    <div className="progress">
      <div className="progress-top">
        <div className="progress-toggle" role="radiogroup" aria-label="What the graphs show">
          {MEASURES.map((m) => (
            <button
              key={m.id}
              role="radio"
              aria-checked={measure === m.id}
              className={measure === m.id ? 'active' : ''}
              onClick={() => setMeasure(m.id)}
            >
              {m.label}
            </button>
          ))}
        </div>
      </div>

      {histories.length === 0 && <p className="progress-empty">No lifts logged yet. Log a workout in the Calendar and it shows up here.</p>}

      {(['upper', 'lower'] as const).map((side) => {
        const list = histories.filter((h) => h.side === side);
        if (!list.length) return null;
        const current = list.filter((h) => h.current);
        const older = list.filter((h) => !h.current);
        return (
          <section key={side} className="progress-side">
            <h2>{side === 'upper' ? 'Upper' : 'Lower'}</h2>
            <div className="progress-grid">
              {current.map((h) => (
                <LiftCard key={h.key} history={h} measure={measure} />
              ))}
            </div>
            {older.length > 0 && (
              <>
                <h3>Older exercises</h3>
                <div className="progress-grid">
                  {older.map((h) => (
                    <LiftCard key={h.key} history={h} measure={measure} />
                  ))}
                </div>
              </>
            )}
          </section>
        );
      })}
    </div>
  );
}

function LiftCard({ history, measure }: { history: LiftHistory; measure: Measure }) {
  const pts = history.points;
  const first = pts[0][measure];
  const last = pts[pts.length - 1][measure];
  const change = last - first;
  // Leave some room above and below the points so none sit on the edge.
  const values = pts.map((pt) => pt[measure]);
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const pad = Math.max((hi - lo) * 0.15, hi * 0.05, 1);
  // Round steps (1, 2, 2.5, 5, 10, 20, 25, 50…) for about four labels on the side.
  const raw = (hi - lo + 2 * pad) / 3;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = ([1, 2, 2.5, 5, 10].find((m) => m * mag >= raw) ?? 10) * mag;
  const bottom = Math.max(0, Math.floor((lo - pad) / step) * step);
  const top = Math.ceil((hi + pad) / step) * step;
  const ticks = Array.from({ length: Math.round((top - bottom) / step) + 1 }, (_, i) => bottom + i * step);
  const trend =
    pts.length < 2 ? 'First session' : change === 0 ? 'Same as first session' : `${change > 0 ? '▲ +' : '▼ −'}${kg(Math.abs(change))} since first session`;

  return (
    <div className="lift-card">
      <div className="lift-head">
        <span className="lift-name">{history.name}</span>
        <span className="lift-latest">{kg(last)}</span>
      </div>
      <div className="lift-trend">{trend}</div>
      <div className="lift-chart">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={pts} margin={{ top: 10, right: 12, bottom: 0, left: -12 }}>
            <CartesianGrid vertical={false} stroke="#33364a" />
            <XAxis
              dataKey="time"
              type="number"
              scale="time"
              domain={['dataMin', 'dataMax']}
              tickFormatter={shortDate}
              tick={{ fill: '#9a9cb0', fontSize: 11 }}
              axisLine={{ stroke: '#3b3e50' }}
              tickLine={false}
              minTickGap={24}
              padding={{ left: 10, right: 10 }}
            />
            <YAxis
              dataKey={measure}
              tick={{ fill: '#9a9cb0', fontSize: 11 }}
              axisLine={false}
              tickLine={false}
              width={48}
              domain={[bottom, top]}
              ticks={ticks}
            />
            <Tooltip content={<LiftTooltip measure={measure} />} cursor={{ stroke: '#5a5e78', strokeWidth: 1 }} />
            <Line
              type="linear"
              dataKey={measure}
              stroke={LINE_COLOR}
              strokeWidth={2}
              dot={{ r: 4, fill: LINE_COLOR, stroke: CARD, strokeWidth: 2 }}
              activeDot={{ r: 6, fill: LINE_COLOR, stroke: CARD, strokeWidth: 2 }}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

function LiftTooltip({ active, payload, measure }: { active?: boolean; payload?: { payload: LiftPoint }[]; measure: Measure }) {
  if (!active || !payload?.length) return null;
  const p = payload[0].payload;
  return (
    <div className="lift-tip">
      <div className="lift-tip-date">
        {new Date(p.time).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })}
      </div>
      <div className={measure === 'heaviest' ? 'strong' : ''}>Heaviest: {p.bestSet}</div>
      <div className={measure === 'volume' ? 'strong' : ''}>
        Volume: {kg(p.volume)} ({p.sets} {p.sets === 1 ? 'set' : 'sets'})
      </div>
    </div>
  );
}
