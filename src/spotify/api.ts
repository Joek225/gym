// Reading your listening stats from Spotify.
import { accessToken } from './auth';

export type TimeRange = 'short_term' | 'medium_term' | 'long_term';
export const TIME_RANGES: { id: TimeRange; label: string }[] = [
  { id: 'short_term', label: 'Last 4 weeks' },
  { id: 'medium_term', label: 'Last 6 months' },
  { id: 'long_term', label: 'All time' },
];

export interface Image {
  url: string;
}
export interface Artist {
  id: string;
  name: string;
  images?: Image[];
  genres?: string[];
  external_urls?: { spotify: string };
}
export interface Track {
  id: string;
  name: string;
  artists: { name: string }[];
  album: { name: string; images: Image[] };
  duration_ms: number;
  external_urls?: { spotify: string };
}
export interface PlayedItem {
  track: Track;
  played_at: string;
}
export interface Profile {
  display_name: string;
  images?: Image[];
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`https://api.spotify.com/v1${path}`, {
    headers: { Authorization: `Bearer ${await accessToken()}` },
  });
  if (!res.ok) throw new Error(`Spotify error ${res.status}`);
  return res.json();
}

export const getProfile = () => get<Profile>('/me');
export const getTopTracks = (range: TimeRange) =>
  get<{ items: Track[] }>(`/me/top/tracks?time_range=${range}&limit=50`).then((r) => r.items);
export const getTopArtists = (range: TimeRange) =>
  get<{ items: Artist[] }>(`/me/top/artists?time_range=${range}&limit=50`).then((r) => r.items);
export const getRecentlyPlayed = () =>
  get<{ items: PlayedItem[] }>('/me/player/recently-played?limit=50').then((r) => r.items);

// Top genres, worked out from your top artists (higher-ranked artists count more).
export function topGenres(artists: Artist[]): { genre: string; share: number }[] {
  const score = new Map<string, number>();
  artists.forEach((a, rank) => {
    for (const g of a.genres ?? []) score.set(g, (score.get(g) ?? 0) + (artists.length - rank));
  });
  const max = Math.max(1, ...score.values());
  return [...score.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 20)
    .map(([genre, s]) => ({ genre, share: s / max }));
}
