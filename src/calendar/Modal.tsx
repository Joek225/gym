// A popup window with a dimmed background. Click outside it or press Escape to close.
import { useEffect, type ReactNode } from 'react';

interface Props {
  onClose: () => void;
  className?: string;
  children: ReactNode;
}

export default function Modal({ onClose, className = '', children }: Props) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${className}`}>{children}</div>
    </div>
  );
}
