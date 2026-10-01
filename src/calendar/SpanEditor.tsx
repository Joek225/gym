// Name (or rename/delete) a label that covers several days, e.g. "Holiday" for Oct 8–10.
import { useState } from 'react';
import { db, type SpanRecord } from '../db';
import { EVENT_COLOR_DARK } from '../gym/workouts';
import { formatShortDate } from './dates';
import Modal from './Modal';

interface Props {
  start: string;
  end: string;
  span?: SpanRecord; // given = editing an existing label
  onClose: () => void;
}

export default function SpanEditor({ start, end, span, onClose }: Props) {
  const [label, setLabel] = useState(span?.label ?? '');

  const save = async () => {
    if (!label.trim()) return;
    await db.spans.put({
      id: span?.id ?? crypto.randomUUID(),
      start,
      end,
      label: label.trim(),
      createdAt: span?.createdAt ?? Date.now(),
    });
    onClose();
  };

  const remove = async () => {
    if (span) await db.spans.delete(span.id);
    onClose();
  };

  return (
    <Modal onClose={onClose} className="event-editor">
      <div className="editor-stripe" style={{ background: EVENT_COLOR_DARK }} />
      <div className="editor-body">
        <div className="muted">
          {formatShortDate(start)} – {formatShortDate(end)}
        </div>
        <input
          className="event-title-input"
          placeholder="What's this? (e.g. Holiday)"
          value={label}
          autoFocus
          onChange={(e) => setLabel(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && save()}
        />
      </div>
      <div className="editor-footer">
        {span && (
          <button className="danger-btn" onClick={remove}>
            Delete
          </button>
        )}
        <button className="link-btn" onClick={onClose}>
          Cancel
        </button>
        <button className="check-btn" onClick={save} disabled={!label.trim()} title="Save">
          ✓
        </button>
      </div>
    </Modal>
  );
}
