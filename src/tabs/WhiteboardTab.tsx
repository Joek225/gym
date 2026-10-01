// Whiteboard tab: a row of boards on top, and the open board below, filling the rest of the page.
//   • The first board is the "To do list" (shows your upcoming calendar events). It can't be
//     renamed or deleted.
//   • Other boards: click the open board's name to rename it; × deletes it.
import { useEffect, useState } from 'react';
import { TODO_BOARD_NAME, db, getSetting, setSetting, type WhiteboardRecord } from '../db';
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
  const [renamingId, setRenamingId] = useState<string | null>(null);

  // Load the list of boards (make the To do list if there are none yet) and reopen the last one.
  useEffect(() => {
    (async () => {
      let list = await db.whiteboard.orderBy('createdAt').toArray();
      if (list.length === 0) list = [await createBoard(TODO_BOARD_NAME)];
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

  const finishRename = async (board: WhiteboardRecord, name: string) => {
    setRenamingId(null);
    name = name.trim();
    if (!name || name === board.name) return;
    await db.whiteboard.update(board.id, { name });
    setBoards((list) => list.map((b) => (b.id === board.id ? { ...b, name } : b)));
  };

  const deleteBoard = async (board: WhiteboardRecord) => {
    await db.whiteboard.delete(board.id);
    const rest = boards.filter((b) => b.id !== board.id);
    setBoards(rest);
    if (board.id === activeId) openBoard(rest[0].id);
  };

  if (!activeId) return <div className="placeholder">Loading…</div>;

  return (
    <div className="whiteboard">
      <div className="board-bar">
        {boards.map((board, index) => {
          const isTodo = index === 0;
          const isActive = board.id === activeId;
          return (
            <div key={board.id} className={isActive ? 'board-chip active' : 'board-chip'}>
              {renamingId === board.id ? (
                <input
                  className="board-rename"
                  defaultValue={board.name}
                  autoFocus
                  onFocus={(e) => e.currentTarget.select()}
                  onBlur={(e) => finishRename(board, e.currentTarget.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') e.currentTarget.blur();
                    if (e.key === 'Escape') setRenamingId(null);
                  }}
                />
              ) : (
                <button
                  className="board-name"
                  title={isActive && !isTodo ? 'Click to rename' : undefined}
                  // Clicking the open board's name renames it (not the To do list).
                  onClick={() => (isActive ? !isTodo && setRenamingId(board.id) : openBoard(board.id))}
                >
                  {board.name}
                </button>
              )}
              {!isTodo && (
                <button className="board-x" title="Delete this board" onClick={() => deleteBoard(board)}>
                  ×
                </button>
              )}
            </div>
          );
        })}
        <button className="board-chip add" onClick={addBoard} title="New board">
          + New
        </button>
      </div>
      <div className="board-canvas">
        {/* "key" makes React build a fresh canvas whenever you switch boards. */}
        <BoardCanvas key={activeId} boardId={activeId} isFirstBoard={boards[0]?.id === activeId} />
      </div>
    </div>
  );
}
