// "Move data" (top right): copy everything out of this browser, or paste it into another one.
import { useState } from 'react';
import Modal from '../calendar/Modal';
import { describeBackup, exportAll, importAll } from '../backup';

export default function MoveData() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className="move-data-btn" onClick={() => setOpen(true)}>
        Move data
      </button>
      {open && <MoveDataPopup onClose={() => setOpen(false)} />}
    </>
  );
}

function MoveDataPopup({ onClose }: { onClose: () => void }) {
  const [copyState, setCopyState] = useState<'idle' | 'working' | 'copied' | 'manual'>('idle');
  const [copied, setCopied] = useState('');
  const [pasted, setPasted] = useState('');
  const [restoring, setRestoring] = useState(false);
  const [error, setError] = useState('');

  const copyAll = async () => {
    setCopyState('working');
    const text = await exportAll();
    setCopied(text);
    try {
      await navigator.clipboard.writeText(text);
      setCopyState('copied');
    } catch {
      setCopyState('manual'); // the browser wouldn't let us: show the text to copy by hand
    }
  };

  const saveFile = () => {
    const url = URL.createObjectURL(new Blob([copied], { type: 'application/json' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = `my-stuff-backup-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  const check = describeBackup(pasted);

  const restore = async () => {
    setRestoring(true);
    setError('');
    try {
      await importAll(pasted);
      window.location.reload(); // show the restored data everywhere
    } catch {
      setError("Couldn't restore that backup. Nothing was changed.");
      setRestoring(false);
    }
  };

  return (
    <Modal onClose={onClose} className="move-data">
      <div className="move-body">
        <h3>Move data to another browser</h3>

        <section>
          <div className="move-step">1. In the browser that has your data</div>
          <button className="move-btn" onClick={copyAll} disabled={copyState === 'working'}>
            {copyState === 'working' ? 'Copying…' : 'Copy everything'}
          </button>
          {copyState === 'copied' && (
            <div className="move-note">
              Copied. Now open this site in the other browser, click Move data, and paste.{' '}
              <button className="link-btn" onClick={saveFile}>
                Also save as a file
              </button>
            </div>
          )}
          {copyState === 'manual' && (
            <>
              <div className="move-note">Select all of this text (Cmd+A) and copy it (Cmd+C):</div>
              <textarea className="move-text" readOnly value={copied} onFocus={(e) => e.currentTarget.select()} />
            </>
          )}
        </section>

        <section>
          <div className="move-step">2. In the new browser</div>
          <textarea
            className="move-text"
            placeholder="Paste here (Cmd+V)"
            value={pasted.length > 2000 ? pasted.slice(0, 2000) + '…' : pasted}
            onChange={(e) => {
              // Only pasting fills the box (below); deleting everything empties it.
              if (!e.target.value) setPasted('');
            }}
            onPaste={(e) => {
              e.preventDefault();
              setPasted(e.clipboardData.getData('text'));
              setError('');
            }}
          />
          <label className="move-file">
            or choose a backup file
            <input
              type="file"
              accept=".json,application/json"
              hidden
              onChange={async (e) => {
                const f = e.target.files?.[0];
                if (f) setPasted(await f.text());
              }}
            />
          </label>
          {pasted && (check.ok ? <div className="move-note">Found: {check.summary}</div> : <div className="move-error">{check.error}</div>)}
          {check.ok && (
            <button className="move-btn danger" onClick={restore} disabled={restoring}>
              {restoring ? 'Restoring…' : 'Replace everything in this browser with this'}
            </button>
          )}
          {error && <div className="move-error">{error}</div>}
        </section>
      </div>
    </Modal>
  );
}
