// Spotify tab: your listening stats, in the style of "Stats for Spotify".
//   Top tracks / Top artists / Top genres — for the last 4 weeks, 6 months, or all time
//   Recently played — your last 50 songs
// First time: a short setup (make a free Spotify developer app, paste its Client ID, connect).
import { useEffect, useState } from 'react';
import {
  TIME_RANGES,
  getProfile,
  getRecentlyPlayed,
  getTopArtists,
  getTopTracks,
  topGenres,
  type Artist,
  type PlayedItem,
  type Profile,
  type TimeRange,
  type Track,
} from '../spotify/api';
import {
  disconnect,
  finishLoginIfReturning,
  getClientId,
  isConnected,
  redirectUri,
  saveClientId,
  startLogin,
} from '../spotify/auth';

type View = 'tracks' | 'artists' | 'genres' | 'recent';
const VIEWS: { id: View; label: string }[] = [
  { id: 'tracks', label: 'Top tracks' },
  { id: 'artists', label: 'Top artists' },
  { id: 'genres', label: 'Top genres' },
  { id: 'recent', label: 'Recently played' },
];

// "3 min ago", "2 h ago", "Yesterday"…
function timeAgo(iso: string): string {
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  return days === 1 ? 'Yesterday' : `${days} days ago`;
}

const smallestImage = (images?: { url: string }[]) => images?.[images.length - 1]?.url ?? images?.[0]?.url;
const largestImage = (images?: { url: string }[]) => images?.[0]?.url;

export default function SpotifyTab() {
  const [stage, setStage] = useState<'loading' | 'setup' | 'connect' | 'ready'>('loading');
  const [error, setError] = useState<string | null>(null);
  const [clientId, setClientId] = useState('');

  // On open: finish a sign-in if Spotify just sent us back, then see where we are.
  useEffect(() => {
    (async () => {
      const problem = await finishLoginIfReturning();
      if (problem) setError(problem);
      const id = await getClientId();
      setClientId(id ?? '');
      setStage(!id ? 'setup' : (await isConnected()) ? 'ready' : 'connect');
    })();
  }, []);

  if (stage === 'loading') return <div className="placeholder">Loading…</div>;

  if (stage === 'setup' || stage === 'connect') {
    return (
      <div className="spotify">
        <div className="sp-setup">
          <h2>Connect Spotify</h2>
          {error && <p className="sp-error">{error}</p>}
          {stage === 'setup' ? (
            <>
              <p className="muted">One-time setup (about 3 minutes). Spotify needs a free "developer app" so this site is allowed to read your stats.</p>
              <ol>
                <li>
                  Go to{' '}
                  <a href="https://developer.spotify.com/dashboard" target="_blank" rel="noreferrer">
                    developer.spotify.com/dashboard
                  </a>{' '}
                  and log in with your Spotify account.
                </li>
                <li>Click <b>Create app</b>. Any name and description is fine (e.g. "My Stuff").</li>
                <li>
                  Under <b>Redirect URIs</b>, paste exactly: <code className="sp-code">{redirectUri()}</code>
                </li>
                <li>Tick <b>Web API</b>, agree to the terms, and click <b>Save</b>.</li>
                <li>Open the app's <b>Settings</b>, copy the <b>Client ID</b>, and paste it here:</li>
              </ol>
              <div className="sp-row">
                <input
                  className="sp-input"
                  placeholder="Client ID"
                  value={clientId}
                  onChange={(e) => setClientId(e.target.value)}
                />
                <button
                  className="sp-btn"
                  disabled={clientId.trim().length < 10}
                  onClick={async () => {
                    await saveClientId(clientId);
                    setStage('connect');
                  }}
                >
                  Save
                </button>
              </div>
            </>
          ) : (
            <>
              <p className="muted">You'll go to Spotify to log in, then come straight back here.</p>
              <div className="sp-row">
                <button className="sp-btn" onClick={() => startLogin()}>
                  Connect Spotify
                </button>
                <button className="link-btn" onClick={() => setStage('setup')}>
                  Change Client ID
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    );
  }

  return (
    <Stats
      onDisconnect={async () => {
        await disconnect();
        setStage('connect');
      }}
    />
  );
}

function Stats({ onDisconnect }: { onDisconnect: () => void }) {
  const [view, setView] = useState<View>('tracks');
  const [range, setRange] = useState<TimeRange>('short_term');
  const [profile, setProfile] = useState<Profile | null>(null);
  const [tracks, setTracks] = useState<Track[] | null>(null);
  const [artists, setArtists] = useState<Artist[] | null>(null);
  const [recent, setRecent] = useState<PlayedItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getProfile().then(setProfile, () => {});
  }, []);

  // Load what the current view needs.
  useEffect(() => {
    setError(null);
    const fail = (e: Error) => setError(e.message);
    if (view === 'tracks') {
      setTracks(null);
      getTopTracks(range).then(setTracks, fail);
    } else if (view === 'artists' || view === 'genres') {
      setArtists(null);
      getTopArtists(range).then(setArtists, fail);
    } else {
      setRecent(null);
      getRecentlyPlayed().then(setRecent, fail);
    }
  }, [view, range]);

  return (
    <div className="spotify">
      <header className="sp-header">
        <div className="sp-me">
          {smallestImage(profile?.images) && <img src={smallestImage(profile?.images)} alt="" />}
          <span>{profile ? profile.display_name : 'Your stats'}</span>
        </div>
        <button className="link-btn" onClick={onDisconnect}>
          Disconnect
        </button>
      </header>

      <nav className="sp-tabs">
        {VIEWS.map((v) => (
          <button key={v.id} className={view === v.id ? 'active' : ''} onClick={() => setView(v.id)}>
            {v.label}
          </button>
        ))}
      </nav>

      {view !== 'recent' && (
        <div className="sp-ranges">
          {TIME_RANGES.map((r) => (
            <button key={r.id} className={range === r.id ? 'active' : ''} onClick={() => setRange(r.id)}>
              {r.label}
            </button>
          ))}
        </div>
      )}

      {error && <p className="sp-error">{error}</p>}

      {view === 'tracks' &&
        (tracks ? (
          <ol className="sp-list">
            {tracks.map((t, i) => (
              <li key={t.id} className="sp-track">
                <span className="sp-rank">{i + 1}</span>
                <img src={smallestImage(t.album.images)} alt="" />
                <span className="sp-track-text">
                  <span className="sp-title">{t.name}</span>
                  <span className="sp-sub">
                    {t.artists.map((a) => a.name).join(', ')} · {t.album.name}
                  </span>
                </span>
              </li>
            ))}
          </ol>
        ) : (
          !error && <div className="placeholder">Loading…</div>
        ))}

      {view === 'artists' &&
        (artists ? (
          <ol className="sp-artists">
            {artists.map((a, i) => (
              <li key={a.id}>
                <div className="sp-artist-img" style={{ backgroundImage: `url(${largestImage(a.images)})` }} />
                <span className="sp-title">
                  <span className="sp-rank-inline">{i + 1}.</span> {a.name}
                </span>
              </li>
            ))}
          </ol>
        ) : (
          !error && <div className="placeholder">Loading…</div>
        ))}

      {view === 'genres' &&
        (artists ? (
          <ol className="sp-genres">
            {topGenres(artists).map((g, i) => (
              <li key={g.genre}>
                <span className="sp-rank">{i + 1}</span>
                <span className="sp-genre-name">{g.genre}</span>
                <span className="sp-bar">
                  <span style={{ width: `${Math.round(g.share * 100)}%` }} />
                </span>
              </li>
            ))}
            {topGenres(artists).length === 0 && <p className="muted">Spotify didn't list genres for your top artists.</p>}
          </ol>
        ) : (
          !error && <div className="placeholder">Loading…</div>
        ))}

      {view === 'recent' &&
        (recent ? (
          <ol className="sp-list">
            {recent.map((p) => (
              <li key={p.played_at} className="sp-track">
                <img src={smallestImage(p.track.album.images)} alt="" />
                <span className="sp-track-text">
                  <span className="sp-title">{p.track.name}</span>
                  <span className="sp-sub">{p.track.artists.map((a) => a.name).join(', ')}</span>
                </span>
                <span className="sp-when">{timeAgo(p.played_at)}</span>
              </li>
            ))}
          </ol>
        ) : (
          !error && <div className="placeholder">Loading…</div>
        ))}
    </div>
  );
}
