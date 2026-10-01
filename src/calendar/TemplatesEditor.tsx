// "Workout templates": edit the exercise lists that pre-fill new Upper and Lower days.
// Changing a template only affects NEW workouts; past workouts stay as logged.
import { useEffect, useState } from 'react';
import { getTemplates, saveTemplates } from '../gym/workouts';
import Modal from './Modal';

export default function TemplatesEditor({ onClose }: { onClose: () => void }) {
  const [upper, setUpper] = useState<string | null>(null);
  const [lower, setLower] = useState('');

  useEffect(() => {
    getTemplates().then((t) => {
      setUpper(t.upper.join('\n'));
      setLower(t.lower.join('\n'));
    });
  }, []);

  // One exercise per line; blank lines are ignored.
  const toList = (text: string) => text.split('\n').map((s) => s.trim()).filter(Boolean);

  const save = async () => {
    await saveTemplates({ upper: toList(upper ?? ''), lower: toList(lower) });
    onClose();
  };

  if (upper === null) return null;
  return (
    <Modal onClose={onClose} className="templates-editor">
      <h3>Workout templates</h3>
      <p className="muted">One exercise per line, in order. Only new workouts use changes.</p>
      <div className="templates-columns">
        <label>
          UPPER
          <textarea rows={11} value={upper} onChange={(e) => setUpper(e.target.value)} />
        </label>
        <label>
          LOWER
          <textarea rows={11} value={lower} onChange={(e) => setLower(e.target.value)} />
        </label>
      </div>
      <div className="editor-footer">
        <button className="link-btn" onClick={onClose}>
          Cancel
        </button>
        <button className="check-btn" onClick={save} title="Save">
          ✓
        </button>
      </div>
    </Modal>
  );
}
