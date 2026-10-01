// Repeating events. Right now: "EcoMiles" every Sunday, 6–10 AM.
// They're saved as normal events (so you can edit, delete or cross out a single one),
// created up to a year ahead and topped up each time the site opens.
import { db, getSetting, setSetting } from '../db';
import { addDays, dateKey, parseKey } from './dates';

const RULES = [
  { key: 'ecomiles', title: 'EcoMiles', weekday: 0 /* Sunday */, time: '06:00-10:00' },
];
const DAYS_AHEAD = 366;

async function ensureRecurring() {
  const today = dateKey(new Date());
  const lastDay = addDays(today, DAYS_AHEAD);
  for (const rule of RULES) {
    const settingKey = `recurring:${rule.key}:until`;
    // Only make dates after the last one we made before (so deleted ones stay deleted).
    const madeUntil = (await getSetting<string>(settingKey)) ?? addDays(today, -1);
    let day = addDays(madeUntil, 1);
    while (parseKey(day).getDay() !== rule.weekday) day = addDays(day, 1);
    for (; day <= lastDay; day = addDays(day, 7)) {
      const id = `${rule.key}-${day}`;
      if (await db.events.get(id)) continue;
      await db.events.add({
        id,
        kind: 'event',
        date: day,
        title: rule.title,
        time: rule.time,
        notes: '',
        struck: false,
        createdAt: Date.now(),
      });
    }
    await setSetting(settingKey, lastDay);
  }
}

// Started once when the site loads; anything that lists events waits for it first.
export const recurringReady = ensureRecurring().catch(() => {});
