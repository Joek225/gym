// The list of tabs shown in the top bar.
// To add a new tab later: make a component in src/tabs/ and add one line here.
import type { ComponentType } from 'react';
import WhiteboardTab from './tabs/WhiteboardTab';
import CalendarTab from './tabs/CalendarTab';
import ProgressTab from './tabs/ProgressTab';
import SpotifyTab from './tabs/SpotifyTab';
import SlideshowsTab from './tabs/SlideshowsTab';

export interface TabInfo {
  id: string; // short name used in the web address, e.g. #/calendar
  label: string; // text shown on the tab button
  component: ComponentType; // what to show when this tab is open
}

export const TABS: TabInfo[] = [
  { id: 'whiteboard', label: 'Whiteboard', component: WhiteboardTab },
  { id: 'slideshows', label: 'Slideshows', component: SlideshowsTab },
  { id: 'calendar', label: 'Calendar', component: CalendarTab },
  { id: 'progress', label: 'Progress', component: ProgressTab },
  { id: 'spotify', label: 'Spotify', component: SpotifyTab },
];
