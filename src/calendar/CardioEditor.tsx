// The cardio popup (opened from the cardio quarter of a zoomed day):
//   speed - incline - hours:mins
//   weight (kg)
// Space (or Enter) jumps to the next box; Backspace in an empty box goes back.
// ✓ saves; "Delete cardio" removes it.
import { useRef, useState, type KeyboardEvent } from 'react';
import type { Cardio } from '../db';
import { CARDIO_COLOR } from '../gym/workouts';
import { formatLongDate } from './dates';
import Modal from './Modal';

const FIELDS: (keyof Cardio)[] = ['speed', 'incline', 'hours', 'mins', 'weight'];
const EMPTY: Cardio = { speed: '', incline: '', hours: '', mins: '', weight: '' };

interface Props {
  date: string;
  cardio?: Cardio;
  onSave: (c: Cardio | undefined) => void; // undefined = delete the cardio
  onClose: () => void;
}

export default function CardioEditor({ date, cardio, onSave, onClose }: Props) {
  const [c, setC] = useState<Cardio>({ ...EMPTY, ...cardio });
  const boxes = useRef<(HTMLInputElement | null)[]>([]);

  const update = (field: keyof Cardio, value: string) => {
    const decimals = field !== 'hours' && field !== 'mins';
    value = value.replace(decimals ? /[^0-9.]/g : /[^0-9]/g, '');
    if (field === 'mins') value = value.slice(0, 2);
    setC({ ...c, [field]: value });
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>, i: number) => {
    if (e.key === 'Enter' && i === FIELDS.length - 1) {
      e.preventDefault();
      onSave(c);
    } else if (e.key === ' ' || e.key === 'Enter' || e.key === '-' || e.key === ':') {
      e.preventDefault();
      boxes.current[i + 1]?.focus();
    } else if (e.key === 'Backspace' && e.currentTarget.value === '' && i > 0) {
      e.preventDefault();
      boxes.current[i - 1]?.focus();
    }
  };

  const box = (i: number, placeholder: string, className = '') => {
    const field = FIELDS[i];
    return (
      <input
        className={`cardio-box ${className}`}
        placeholder={placeholder}
        inputMode={field === 'hours' || field === 'mins' ? 'numeric' : 'decimal'}
        value={c[field] ?? ''}
        autoFocus={i === 0}
        ref={(el) => void (boxes.current[i] = el)}
        onChange={(e) => update(field, e.target.value)}
        onKeyDown={(e) => onKey(e, i)}
      />
    );
  };

  return (
    <Modal onClose={onClose} className="workout-editor">
      <div className="workout-header" style={{ background: CARDIO_COLOR }}>
        <span className="workout-type">Cardio</span>
        <span className="workout-date">{formatLongDate(date)}</span>
      </div>
      <div className="cardio-sheet">
        <div className="workout-legend">speed - incline - hours:mins</div>
        <div className="cardio-line">
          {box(0, 'speed')}
          <span>-</span>
          {box(1, 'incline')}
          <span>-</span>
          {box(2, 'h', 'cardio-hours')}
          <span>:</span>
          {box(3, 'mm', 'cardio-mins')}
        </div>
        <div className="workout-legend cardio-weight-label">weight</div>
        <div className="cardio-line">
          {box(4, 'kg', 'cardio-weight')}
          <span className="muted-unit">kg</span>
        </div>
      </div>
      <div className="editor-footer">
        {cardio && (
          <button className="danger-btn" onClick={() => onSave(undefined)}>
            Delete cardio
          </button>
        )}
        <button className="link-btn" onClick={onClose}>
          Cancel
        </button>
        <button className="check-btn" onClick={() => onSave(c)} title="Save">
          ✓
        </button>
      </div>
    </Modal>
  );
}
