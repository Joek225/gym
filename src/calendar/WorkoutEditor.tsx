// The workout sheet (what opens from the red side of a day).
// Each line reads:  exercise - weight - reps - partial reps
//   • Upper/Lower days start with the template's exercise names already filled in.
//   • Custom days (Wed/Sat/Sun, and every day under a blue holiday label) start empty and get a name of your choice.
//   • Weight is in kg (numbers only). Partial reps are optional.
// Typing shortcuts (you never need to type the dashes):
//   exercise: Enter, or " -"      → weight
//   weight:   Space or Enter      → reps
//   reps:     Space               → partial reps
//   partial:  Space               → next line   (so Space Space after reps skips partials)
//   reps or partial: Enter        → another set of the same exercise, on a new line below
//   Backspace in an empty box     → back one box
// A line whose exercise name is left empty disappears when you leave it.
// Some exercises (e.g. Lateral Raise) first ask which kind — "Cable | Dumbbell" — and the
// choice becomes the name ("Cable Lateral Raise"); then the normal boxes appear.
// You can't close the sheet while a line is half done: once a line is started it needs
// reps AND weight (partial reps can stay empty). Untouched template lines are fine.
import { useEffect, useRef, useState, type FocusEvent, type KeyboardEvent } from 'react';
import { db, type WorkoutRecord, type WorkoutRow } from '../db';
import { GYM_COLOR, VARIANTS, saveWorkout, workoutLabel } from '../gym/workouts';
import { formatLongDate } from './dates';
import Modal from './Modal';

interface Props {
  workout: WorkoutRecord; // existing, or a fresh one from newWorkout()
  onClose: () => void; // ✓, ×, Escape, or deleted
}

type Field = 'name' | 'reps' | 'partial' | 'weight';
const FIELDS: Field[] = ['name', 'weight', 'reps', 'partial'];
const isSeparator = (key: string) => key === ' ' || key === '-';

export default function WorkoutEditor({ workout, onClose }: Props) {
  const [w, setW] = useState(workout);
  const inputs = useRef(new Map<string, HTMLInputElement>()); // "row:field" → input box
  const [focusNext, setFocusNext] = useState<string | null>(null);
  const isCustom = w.type === 'custom';

  // Places you've trained before, offered as suggestions in the location box.
  const [places, setPlaces] = useState<string[]>([]);
  useEffect(() => {
    db.workouts.toArray().then((all) => {
      const seen = new Set(all.map((x) => x.location?.trim()).filter((x): x is string => !!x));
      setPlaces([...seen].sort());
    });
  }, []);

  // Save every change right away (an empty workout is not kept).
  useEffect(() => {
    saveWorkout(w);
  }, [w]);

  // Move the typing cursor to a box (after React has drawn any new line).
  useEffect(() => {
    if (!focusNext) return;
    const el = inputs.current.get(focusNext);
    el?.focus();
    el?.setSelectionRange(el.value.length, el.value.length);
    setFocusNext(null);
  }, [focusNext, w]);

  const go = (row: number, field: Field) => setFocusNext(`${row}:${field}`);

  // Which lines are started but missing reps or weight (or a name).
  const [showMissing, setShowMissing] = useState(false);
  const isIncomplete = (r: WorkoutRow) => {
    const started = r.reps || r.partial || r.weight || (isCustom && r.name.trim());
    return !!started && (!r.name.trim() || !r.reps || !r.weight);
  };
  const missing = w.rows.map(isIncomplete);

  // Close only if every started line is complete; otherwise point at the first gap.
  const tryClose = () => {
    const i = missing.indexOf(true);
    if (i === -1) return onClose();
    setShowMissing(true);
    const r = w.rows[i];
    go(i, !r.name.trim() ? 'name' : !r.weight ? 'weight' : 'reps');
  };

  const updateRow = (i: number, patch: Partial<WorkoutRow>) =>
    setW((cur) => ({ ...cur, rows: cur.rows.map((r, j) => (j === i ? { ...r, ...patch } : r)) }));

  // Insert a new line at position `at` and put the cursor in it.
  const addRow = (at: number, name = '') => {
    setW((cur) => {
      const rows = [...cur.rows];
      rows.splice(at, 0, { name, reps: '', partial: '', weight: '' });
      return { ...cur, rows };
    });
    go(at, name ? 'weight' : 'name');
  };

  // Leaving a line with no exercise name removes it.
  const onRowBlur = (e: FocusEvent<HTMLDivElement>, i: number) => {
    if (e.currentTarget.contains(e.relatedTarget as Node)) return; // still inside this line
    if (!w.rows[i]?.name.trim()) setW((cur) => ({ ...cur, rows: cur.rows.filter((_, j) => j !== i) }));
  };

  const nextLine = (i: number) => {
    if (i + 1 < w.rows.length) go(i + 1, w.rows[i + 1].name ? 'weight' : 'name');
    else addRow(w.rows.length);
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>, i: number, field: Field) => {
    const value = e.currentTarget.value;
    const move = (f: Field) => {
      e.preventDefault();
      go(i, f);
    };
    if (e.key === 'Backspace' && value === '') {
      e.preventDefault();
      const f = FIELDS.indexOf(field);
      if (f > 0) go(i, FIELDS[f - 1]);
      else if (i > 0) go(i - 1, 'partial');
    } else if (field === 'name') {
      if (e.key === 'Enter' || (e.key === '-' && value.endsWith(' '))) {
        updateRow(i, { name: value.trim() });
        move('weight');
      }
    } else if (field === 'weight') {
      if (isSeparator(e.key) || e.key === 'Enter') {
        if (value) move('reps');
        else e.preventDefault(); // nothing typed yet: ignore
      }
    } else if (e.key === 'Enter') {
      // reps or partial: another set of the same exercise
      e.preventDefault();
      if (w.rows[i].reps) addRow(i + 1, w.rows[i].name);
    } else if (isSeparator(e.key)) {
      e.preventDefault();
      if (field === 'reps') {
        if (value) go(i, 'partial');
      } else nextLine(i); // empty partial = skip partials
    }
  };

  const digitsOnly = (text: string) => text.replace(/[^0-9]/g, '');

  const remove = async () => {
    await saveWorkout({ ...w, customName: '', rows: [] }); // empty = deleted
    onClose();
  };

  // Each box remembers itself so the cursor can be moved to it.
  const boxRef = (i: number, f: Field) => (el: HTMLInputElement | null) => {
    if (el) inputs.current.set(`${i}:${f}`, el);
    else inputs.current.delete(`${i}:${f}`);
  };

  return (
    <Modal onClose={tryClose} className="workout-editor">
      <div className="workout-header" style={{ background: GYM_COLOR }}>
        {isCustom ? (
          <input
            className="workout-name-input"
            placeholder="Name this workout"
            value={w.customName}
            autoFocus={!w.customName}
            onChange={(e) => setW({ ...w, customName: e.target.value })}
            onKeyDown={(e) => e.key === 'Enter' && (w.rows.length ? go(0, 'name') : addRow(0))}
          />
        ) : (
          <span className="workout-type">{workoutLabel(w)}</span>
        )}
        <span className="workout-date">{formatLongDate(w.date)}</span>
        <input
          className="workout-location-input"
          placeholder="Add location"
          list="workout-places"
          value={w.location ?? ''}
          onChange={(e) => setW({ ...w, location: e.target.value })}
        />
        <datalist id="workout-places">
          {places.map((place) => (
            <option key={place} value={place} />
          ))}
        </datalist>
      </div>

      <div className="workout-lines">
        <div className="workout-legend">exercise - weight - reps - partial reps</div>
        {w.rows.map((row, i) =>
          VARIANTS[row.name] ? (
            // Pick a kind first; the boxes appear once one is picked.
            <div className="workout-line" key={i}>
              <span className="wl-name wl-static">{row.name}</span>
              <span className="variant-pick">
                {VARIANTS[row.name].map((kind, k) => (
                  <span key={kind}>
                    {k > 0 && <span className="wl-dash"> | </span>}
                    <button
                      className="link-btn"
                      onClick={() => {
                        updateRow(i, { name: `${kind} ${row.name}` });
                        go(i, 'weight');
                      }}
                    >
                      {kind}
                    </button>
                  </span>
                ))}
              </span>
            </div>
          ) : (
          <div
            className={showMissing && missing[i] ? 'workout-line missing' : 'workout-line'}
            key={i}
            onBlur={(e) => onRowBlur(e, i)}
          >
            <input
              className="wl-name"
              placeholder="exercise"
              value={row.name}
              ref={boxRef(i, 'name')}
              onChange={(e) => updateRow(i, { name: e.target.value })}
              onKeyDown={(e) => onKey(e, i, 'name')}
            />
            <span className="wl-dash">-</span>
            <input
              className="wl-num wl-weight"
              placeholder="kg"
              inputMode="decimal"
              value={row.weight}
              autoFocus={!isCustom && i === 0 && !row.weight}
              ref={boxRef(i, 'weight')}
              onChange={(e) => updateRow(i, { weight: e.target.value.replace(/[^0-9.]/g, '') })}
              onKeyDown={(e) => onKey(e, i, 'weight')}
            />
            <span className="wl-dash">-</span>
            <input
              className="wl-num"
              placeholder="reps"
              inputMode="numeric"
              value={row.reps}
              ref={boxRef(i, 'reps')}
              onChange={(e) => updateRow(i, { reps: digitsOnly(e.target.value) })}
              onKeyDown={(e) => onKey(e, i, 'reps')}
            />
            <span className="wl-dash">-</span>
            <input
              className="wl-num wl-partial"
              placeholder="partial"
              inputMode="numeric"
              value={row.partial ?? ''}
              ref={boxRef(i, 'partial')}
              onChange={(e) => updateRow(i, { partial: digitsOnly(e.target.value) })}
              onKeyDown={(e) => onKey(e, i, 'partial')}
            />
          </div>
          ),
        )}
        <button className="link-btn add-line" onClick={() => addRow(w.rows.length)}>
          + Add line
        </button>
      </div>

      {showMissing && missing.includes(true) && (
        <div className="workout-warning">Add weight and reps to the highlighted lines (partials can stay empty).</div>
      )}

      <div className="editor-footer">
        <button className="danger-btn" onClick={remove}>
          Delete workout
        </button>
        <button className="check-btn" onClick={tryClose} title="Done">
          ✓
        </button>
      </div>
    </Modal>
  );
}
