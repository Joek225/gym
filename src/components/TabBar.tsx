// The row of tab buttons across the top of the page.
import type { TabInfo } from '../tabs';

interface Props {
  tabs: TabInfo[];
  activeId: string;
  onSelect: (id: string) => void;
}

export default function TabBar({ tabs, activeId, onSelect }: Props) {
  return (
    <nav className="tab-bar">
      {tabs.map((tab) => (
        <button
          key={tab.id}
          className={tab.id === activeId ? 'tab active' : 'tab'}
          onClick={() => onSelect(tab.id)}
        >
          {tab.label}
        </button>
      ))}
    </nav>
  );
}
