// The workout sheet (what opens from the red side of a day).
// Each line reads:  exercise - reps - partial reps - weight
//   • Upper/Lower days start with the template's exercise names already filled in.
//   • Custom days (Wed/Sat/Sun) start empty and get a name of your choice.
//   • Weight can be a number (kg) or a word like "stack". Partial reps are optional.
// Typing shortcuts (you never need to type the dashes):
//   exercise: Enter, or " -"      → reps
//   reps:     Space               → partial reps
//   partial:  Space               → weight   (so Space Space after reps skips partials)
//   weight:   Space               → next line
//             Enter               → another set of the same exercise, on a new line below
//   Backspace in an empty box     → back one box
// A line whose exercise name is left empty disappears when you leave it.
// You can't close the sheet while a line is half done: once a line is started it needs
// reps AND weight (partial reps can stay empty). Untouched template lines are fine.
import { useEffect, useRef, useState, type FocusEvent, type KeyboardEvent } from 'react';
import type { WorkoutRecord, WorkoutRow } from '../db';
import { GYM_COLOR, saveWorkout, workoutLabel } from '../gym/workouts';
import { formatLongDate } from './dates';
import Modal from './Modal';

interface Props {
  workout: WorkoutRecord; // existing, or a fresh one from newWorkout()
  onClose: () => void; // ✓, ×, Escape, or deleted
}

type Field = 'name' | 'reps' | 'partial' | 'weight';
const FIELDS: Field[] = ['name', 'reps', 'partial', 'weight'];
const isSeparator = (key: string) => key === ' ' || key === '-';

export default function WorkoutEditor({ workout, onClose }: Props) {
  const [w, setW] = useState(workout);
  const inputs = useRef(new Map<string, HTMLInputElement>()); // "row:field" → input box
  const [focusNext, setFocusNext] = useState<string | null>(null);
  const isCustom = w.type === 'custom';

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
    go(i, !r.name.trim() ? 'name' : !r.reps ? 'reps' : 'weight');
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
    go(at, name ? 'reps' : 'name');
  };

  // Leaving a line with no exercise name removes it.
  const onRowBlur = (e: FocusEvent<HTMLDivElement>, i: number) => {
    if (e.currentTarget.contains(e.relatedTarget as Node)) return; // still inside this line
    if (!w.rows[i]?.name.trim()) setW((cur) => ({ ...cur, rows: cur.rows.filter((_, j) => j !== i) }));
  };

  const nextLine = (i: number) => {
    if (i + 1 < w.rows.length) go(i + 1, w.rows[i + 1].name ? 'reps' : 'name');
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
      else if (i > 0) go(i - 1, 'weight');
    } else if (field === 'name') {
      if (e.key === 'Enter' || (e.key === '-' && value.endsWith(' '))) {
        updateRow(i, { name: value.trim() });
        move('reps');
      }
    } else if (field === 'reps') {
      if (isSeparator(e.key) || e.key === 'Enter') {
        if (value) move('partial');
        else e.preventDefault(); // nothing typed yet: ignore
      }
    } else if (field === 'partial') {
      if (isSeparator(e.key) || e.key === 'Enter') move('weight'); // empty = skip partials
    } else if (field === 'weight') {
      if (isSeparator(e.key)) {
        e.preventDefault();
        if (value) nextLine(i);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        addRow(i + 1, w.rows[i].name); // another set of the same exercise
      }
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
      </div>

      <div className="workout-lines">
        <div className="workout-legend">exercise - reps - partial reps - weight</div>
        {w.rows.map((row, i) => (
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
              className="wl-num"
              placeholder="reps"
              inputMode="numeric"
              value={row.reps}
              autoFocus={!isCustom && i === 0 && !row.reps}
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
            <span className="wl-dash">-</span>
            <input
              className="wl-num wl-weight"
              placeholder="kg"
              value={row.weight}
              ref={boxRef(i, 'weight')}
              onChange={(e) => updateRow(i, { weight: e.target.value.replace(/[\s-]/g, '') })}
              onKeyDown={(e) => onKey(e, i, 'weight')}
            />
          </div>
        ))}
        <button className="link-btn add-line" onClick={() => addRow(w.rows.length)}>
          + Add line
        </button>
      </div>

      {showMissing && missing.includes(true) && (
        <div className="workout-warning">Add reps and weight to the highlighted lines (partials can stay empty).</div>
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
