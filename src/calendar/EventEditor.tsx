// Add / edit / delete one event or reminder — a small Google-Calendar-style card.
// Time: type a clock time in the box, or use the ▾ arrow next to it to pick a school block.
// Leaving the time empty is fine.
import { useState, type CSSProperties } from 'react';
import { db, type EventRecord } from '../db';
import { EVENT_COLOR, REMINDER_COLOR } from '../gym/workouts';
import { BLOCKS, formatLongDate, formatTime } from './dates';
import Modal from './Modal';

interface Props {
  date: string;
  kind: 'event' | 'reminder';
  event?: EventRecord; // given = editing an existing one; missing = adding a new one
  onSaved: () => void; // after ✓
  onClose: () => void; // after × / Escape / delete
}

const isClock = (t: string) => /^\d{1,2}:\d{2}$/.test(t);
const CLOCK_OPTION = '__clock__'; // the "Time" choice in the dropdown: back to a clock time

export default function EventEditor({ date, kind, event, onSaved, onClose }: Props) {
  const [title, setTitle] = useState(event?.title ?? '');
  const [time, setTime] = useState(event?.time ?? '');
  const [notes, setNotes] = useState(event?.notes ?? '');
  const isReminder = (event?.kind ?? kind) === 'reminder';

  const save = async () => {
    if (!title.trim()) return; // a title is needed
    await db.events.put({
      id: event?.id ?? crypto.randomUUID(),
      kind: isReminder ? 'reminder' : 'event',
      date,
      title: title.trim(),
      time,
      notes: notes.trim(),
      struck: event?.struck ?? false,
      createdAt: event?.createdAt ?? Date.now(),
    });
    onSaved();
  };

  const remove = async () => {
    if (!event) return;
    await db.events.delete(event.id);
    onClose();
  };

  return (
    <Modal onClose={onClose} className="event-editor">
      <div className="editor-stripe" style={{ background: isReminder ? REMINDER_COLOR : EVENT_COLOR }} />
      <div className="editor-body">
        <input
          className="event-title-input"
          style={{ '--focus-line': isReminder ? REMINDER_COLOR : EVENT_COLOR } as CSSProperties}
          placeholder={isReminder ? 'Add reminder' : 'Add title'}
          value={title}
          autoFocus
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && save()}
        />
        <div className="editor-row">
          <span>{formatLongDate(date)}</span>
          {/* A typed clock time — or, if a block was picked, its name instead. */}
          {time && !isClock(time) ? (
            <span className="time-chip">{formatTime(time)}</span>
          ) : (
            <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          )}
          {/* Just a ▾ arrow: pick a school block, or "Time" to go back to a clock time */}
          <select
            className="block-arrow"
            value=""
            title="Pick a block"
            onChange={(e) => setTime(e.target.value === CLOCK_OPTION ? '' : e.target.value)}
          >
            <option value="" disabled hidden>
              ▾
            </option>
            <option value={CLOCK_OPTION}>Time</option>
            {BLOCKS.map((b) => (
              <option key={b} value={b}>
                {b}
              </option>
            ))}
          </select>
        </div>
        <div className="editor-row">
          <span className="editor-icon">≡</span>
          <textarea
            placeholder="Add notes"
            rows={3}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
        </div>
      </div>
      <div className="editor-footer">
        {event && (
          <button className="danger-btn" onClick={remove}>
            Delete
          </button>
        )}
        <button className="link-btn" onClick={onClose}>
          Cancel
        </button>
        <button className="check-btn" onClick={save} disabled={!title.trim()} title="Save">
          ✓
        </button>
      </div>
    </Modal>
  );
}
