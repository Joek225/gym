// Whiteboard tab: a row of boards on top (switch / add / rename / delete),
// and the open board below, filling the rest of the page.
import { useEffect, useState } from 'react';
import { db, getSetting, setSetting, type WhiteboardRecord } from '../db';
import BoardCanvas from '../whiteboard/BoardCanvas';

const ACTIVE_BOARD_KEY = 'activeBoardId';

async function createBoard(name: string): Promise<WhiteboardRecord> {
  const now = Date.now();
  const board = { id: crypto.randomUUID(), name, data: null, createdAt: now, updatedAt: now };
  await db.whiteboard.add(board);
  return board;
}

export default function WhiteboardTab() {
  const [boards, setBoards] = useState<WhiteboardRecord[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);

  // Load the list of boards (make one if there are none yet) and reopen the last one used.
  useEffect(() => {
    (async () => {
      let list = await db.whiteboard.orderBy('createdAt').toArray();
      if (list.length === 0) list = [await createBoard('Board 1')];
      const lastId = await getSetting<string>(ACTIVE_BOARD_KEY);
      setBoards(list);
      setActiveId(list.some((b) => b.id === lastId) ? lastId! : list[0].id);
    })();
  }, []);

  const openBoard = (id: string) => {
    setActiveId(id);
    setSetting(ACTIVE_BOARD_KEY, id);
  };

  const addBoard = async () => {
    const board = await createBoard(`Board ${boards.length + 1}`);
    setBoards([...boards, board]);
    openBoard(board.id);
  };

  const renameBoard = async (board: WhiteboardRecord) => {
    const name = window.prompt('Rename board:', board.name)?.trim();
    if (!name) return;
    await db.whiteboard.update(board.id, { name });
    setBoards(boards.map((b) => (b.id === board.id ? { ...b, name } : b)));
  };

  const deleteBoard = async (board: WhiteboardRecord) => {
    if (!window.confirm(`Delete "${board.name}"? This can't be undone.`)) return;
    await db.whiteboard.delete(board.id);
    let rest = boards.filter((b) => b.id !== board.id);
    if (rest.length === 0) rest = [await createBoard('Board 1')]; // always keep one board
    setBoards(rest);
    openBoard(rest[0].id);
  };

  if (!activeId) return <div className="placeholder">Loading…</div>;
  const active = boards.find((b) => b.id === activeId)!;

  return (
    <div className="whiteboard">
      <div className="board-bar">
        <div className="board-list">
          {boards.map((board) => (
            <button
              key={board.id}
              className={board.id === activeId ? 'board-chip active' : 'board-chip'}
              onClick={() => openBoard(board.id)}
              onDoubleClick={() => renameBoard(board)}
            >
              {board.name}
            </button>
          ))}
          <button className="board-chip add" onClick={addBoard} title="New board">
            + New
          </button>
        </div>
        <div className="board-actions">
          <button onClick={() => renameBoard(active)} title="Rename this board">
            Rename
          </button>
          <button onClick={() => deleteBoard(active)} title="Delete this board">
            Delete
          </button>
        </div>
      </div>
      <div className="board-canvas">
        {/* "key" makes React build a fresh canvas whenever you switch boards. */}
        <BoardCanvas key={activeId} boardId={activeId} isFirstBoard={boards[0]?.id === activeId} />
      </div>
    </div>
  );
}
