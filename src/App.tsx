// The main layout: tab bar on top, the open tab's content below.
import { useEffect, useState } from 'react';
import TabBar from './components/TabBar';
import { TABS } from './tabs';

// The open tab is saved in the web address (e.g. ".../gym/#/calendar"),
// so refreshing the page keeps you on the same tab.
function tabFromAddress(): string {
  const id = window.location.hash.replace('#/', '');
  return TABS.some((t) => t.id === id) ? id : TABS[0].id;
}

export default function App() {
  const [activeId, setActiveId] = useState(tabFromAddress);

  // Keep the tab in sync if the address changes (e.g. browser Back button).
  useEffect(() => {
    const onHashChange = () => setActiveId(tabFromAddress());
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  const selectTab = (id: string) => {
    window.location.hash = '/' + id; // this also triggers onHashChange above
  };

  const ActiveTab = TABS.find((t) => t.id === activeId)!.component;

  return (
    <div className="app">
      <TabBar tabs={TABS} activeId={activeId} onSelect={selectTab} />
      <main className="tab-content">
        <ActiveTab />
      </main>
    </div>
  );
}
