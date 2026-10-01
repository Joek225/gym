// The workout sheet (what opens from the red side of a day).
// Each line reads:  exercise name - reps - weight
//   • Upper/Lower days start with the template's exercise names already filled in.
//   • Custom days (Wed/Sat/Sun) start empty and get a name of your choice.
// Typing shortcuts:
//   name:   Enter, or " -"        → jump to reps
//   reps:   Space, Enter, or "-"  → jump to weight
//   weight: Enter                 → next line (a new line is added at the end)
//   Backspace in an empty box     → go back one box
import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import type { WorkoutRecord, WorkoutRow } from '../db';
import { GYM_COLOR, saveWorkout, workoutLabel } from '../gym/workouts';
import { formatLongDate } from './dates';
import Modal from './Modal';

interface Props {
  workout: WorkoutRecord; // existing, or a fresh one from newWorkout()
  onDone: () => void; // ✓ pressed
  onClose: () => void; // × / Escape / deleted
}

type Field = 'name' | 'reps' | 'weight';
const FIELDS: Field[] = ['name', 'reps', 'weight'];

export default function WorkoutEditor({ workout, onDone, onClose }: Props) {
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

  const updateRow = (i: number, patch: Partial<WorkoutRow>) =>
    setW({ ...w, rows: w.rows.map((r, j) => (j === i ? { ...r, ...patch } : r)) });

  const addRow = (at: number, name = '') => {
    const rows = [...w.rows];
    rows.splice(at, 0, { name, reps: '', weight: '' });
    setW({ ...w, rows });
    go(at, name ? 'reps' : 'name');
  };

  const removeRow = (i: number) => setW({ ...w, rows: w.rows.filter((_, j) => j !== i) });

  const onKey = (e: KeyboardEvent<HTMLInputElement>, i: number, field: Field) => {
    const value = e.currentTarget.value;
    const back = () => {
      const f = FIELDS.indexOf(field);
      if (f > 0) go(i, FIELDS[f - 1]);
      else if (i > 0) go(i - 1, 'weight');
    };
    if (e.key === 'Backspace' && value === '') {
      e.preventDefault();
      back();
    } else if (field === 'name') {
      if (e.key === 'Enter' || (e.key === '-' && value.endsWith(' '))) {
        e.preventDefault();
        updateRow(i, { name: value.trim() });
        go(i, 'reps');
      }
    } else if (field === 'reps') {
      if (e.key === ' ' || e.key === 'Enter' || e.key === '-') {
        e.preventDefault();
        if (value !== '') go(i, 'weight'); // leading space/dash just gets ignored
      }
    } else if (field === 'weight') {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (i + 1 < w.rows.length) go(i + 1, isCustom ? 'name' : 'reps');
        else addRow(w.rows.length);
      } else if (e.key === ' ' || e.key === '-') {
        e.preventDefault(); // no spaces/dashes inside a weight
      }
    }
  };

  const numbersOnly = (text: string, decimals: boolean) =>
    text.replace(decimals ? /[^0-9.]/g : /[^0-9]/g, '');

  const remove = async () => {
    if (!window.confirm('Delete this workout?')) return;
    await saveWorkout({ ...w, customName: '', rows: [] }); // empty = deleted
    onClose();
  };

  return (
    <Modal onClose={onClose} className="workout-editor">
      <div className="workout-header" style={{ background: GYM_COLOR }}>
        {isCustom ? (
          <input
            className="workout-name-input"
            placeholder="Name this workout"
            value={w.customName}
            autoFocus={!w.customName}
            onChange={(e) => setW({ ...w, customName: e.target.value })}
            onKeyDown={(e) => e.key === 'Enter' && go(0, 'name')}
          />
        ) : (
          <span className="workout-type">{workoutLabel(w)}</span>
        )}
        <span className="workout-date">{formatLongDate(w.date)}</span>
      </div>

      <div className="workout-lines">
        <div className="workout-legend">exercise - reps - weight (kg)</div>
        {w.rows.map((row, i) => (
          <div className="workout-line" key={i}>
            <input
              className="wl-name"
              placeholder="exercise"
              value={row.name}
              ref={(el) => void (el ? inputs.current.set(`${i}:name`, el) : inputs.current.delete(`${i}:name`))}
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
              ref={(el) => void (el ? inputs.current.set(`${i}:reps`, el) : inputs.current.delete(`${i}:reps`))}
              onChange={(e) => updateRow(i, { reps: numbersOnly(e.target.value, false) })}
              onKeyDown={(e) => onKey(e, i, 'reps')}
            />
            <span className="wl-dash">-</span>
            <input
              className="wl-num wl-weight"
              placeholder="kg"
              inputMode="decimal"
              value={row.weight}
              ref={(el) => void (el ? inputs.current.set(`${i}:weight`, el) : inputs.current.delete(`${i}:weight`))}
              onChange={(e) => updateRow(i, { weight: numbersOnly(e.target.value, true) })}
              onKeyDown={(e) => onKey(e, i, 'weight')}
            />
            <span className="wl-actions">
              <button title="Add another set of this exercise below" onClick={() => addRow(i + 1, row.name)}>
                +
              </button>
              <button title="Remove this line" onClick={() => removeRow(i)}>
                ×
              </button>
            </span>
          </div>
        ))}
        <button className="link-btn add-line" onClick={() => addRow(w.rows.length)}>
          + Add line
        </button>
      </div>

      <div className="editor-footer">
        <button className="danger-btn" onClick={remove}>
          Delete workout
        </button>
        <button className="check-btn" onClick={onDone} title="Done">
          ✓
        </button>
      </div>
    </Modal>
  );
}
