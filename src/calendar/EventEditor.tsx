// Add / edit / delete one event — a small Google-Calendar-style card.
import { useState } from 'react';
import { db, type EventRecord } from '../db';
import { EVENT_COLOR } from '../gym/workouts';
import { formatLongDate } from './dates';
import Modal from './Modal';

interface Props {
  date: string;
  event?: EventRecord; // given = editing an existing event; missing = adding a new one
  onSaved: () => void; // after ✓
  onClose: () => void; // after × / Escape / delete
}

export default function EventEditor({ date, event, onSaved, onClose }: Props) {
  const [title, setTitle] = useState(event?.title ?? '');
  const [time, setTime] = useState(event?.time ?? '');
  const [notes, setNotes] = useState(event?.notes ?? '');

  const save = async () => {
    if (!title.trim()) return; // a title is needed
    await db.events.put({
      id: event?.id ?? crypto.randomUUID(),
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
    if (!event || !window.confirm(`Delete "${event.title}"?`)) return;
    await db.events.delete(event.id);
    onClose();
  };

  return (
    <Modal onClose={onClose} className="event-editor">
      <div className="editor-stripe" style={{ background: EVENT_COLOR }} />
      <div className="editor-body">
        <input
          className="event-title-input"
          placeholder="Add title"
          value={title}
          autoFocus
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && save()}
        />
        <div className="editor-row">
          <span className="editor-icon">🕒</span>
          <span>{formatLongDate(date)}</span>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          {time && (
            <button className="link-btn" onClick={() => setTime('')}>
              no time
            </button>
          )}
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
