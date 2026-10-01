// The cardio line under the workout in the zoomed day, typed straight in:
//   speed - incline - hours:mins
// Space (or Enter) jumps to the next box; Backspace in an empty box goes back.
import { useRef, useState, type KeyboardEvent } from 'react';
import type { Cardio } from '../db';

const FIELDS: (keyof Cardio)[] = ['speed', 'incline', 'hours', 'mins'];
const EMPTY: Cardio = { speed: '', incline: '', hours: '', mins: '' };

interface Props {
  cardio?: Cardio;
  onChange: (c: Cardio) => void;
}

export default function CardioEditor({ cardio, onChange }: Props) {
  const [c, setC] = useState<Cardio>(cardio ?? EMPTY);
  const boxes = useRef<(HTMLInputElement | null)[]>([]);

  const update = (field: keyof Cardio, value: string) => {
    const decimals = field === 'speed' || field === 'incline';
    value = value.replace(decimals ? /[^0-9.]/g : /[^0-9]/g, '');
    if (field === 'mins') value = value.slice(0, 2);
    const next = { ...c, [field]: value };
    setC(next);
    onChange(next);
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>, i: number) => {
    if (e.key === ' ' || e.key === 'Enter' || e.key === '-' || e.key === ':') {
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
        inputMode={i < 2 ? 'decimal' : 'numeric'}
        value={c[field]}
        ref={(el) => void (boxes.current[i] = el)}
        onChange={(e) => update(field, e.target.value)}
        onKeyDown={(e) => onKey(e, i)}
      />
    );
  };

  return (
    // Clicks here shouldn't open the workout sheet behind it.
    <div className="cardio" onClick={(e) => e.stopPropagation()}>
      <div className="cardio-title">Cardio</div>
      <div className="cardio-line">
        {box(0, 'speed')}
        <span>-</span>
        {box(1, 'incline')}
        <span>-</span>
        {box(2, 'h', 'cardio-hours')}
        <span>:</span>
        {box(3, 'mm', 'cardio-mins')}
      </div>
    </div>
  );
}
