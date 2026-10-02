// Signing in to Spotify, without a server: the "Authorization Code with PKCE" flow.
//   1. You make a free Spotify developer app and paste its Client ID here (once).
//   2. "Connect Spotify" sends you to Spotify's own login page.
//   3. Spotify sends you back here with a one-time code, which we swap for an access key.
// The keys are saved in this browser only (like everything else on the site).
import { getSetting, setSetting, db } from '../db';

const CLIENT_ID_KEY = 'spotify:clientId';
const AUTH_KEY = 'spotify:auth';
const SCOPES = 'user-top-read user-read-recently-played';

interface SavedAuth {
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // milliseconds since 1970
}

// Where Spotify sends you back after logging in: this site's address, e.g.
// https://joek225.github.io/gym/  (it must be listed in your Spotify app's settings).
export function redirectUri(): string {
  return window.location.origin + import.meta.env.BASE_URL;
}

export const getClientId = () => getSetting<string>(CLIENT_ID_KEY);
export const saveClientId = (id: string) => setSetting(CLIENT_ID_KEY, id.trim());

export async function isConnected(): Promise<boolean> {
  return !!(await getSetting<SavedAuth>(AUTH_KEY));
}

export async function disconnect() {
  await db.settings.delete(AUTH_KEY);
}

// ---- small helpers for PKCE ----
function randomString(length: number): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (b) => chars[b % chars.length]).join('');
}

async function sha256Base64Url(text: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

// Step 2: go to Spotify's login page.
export async function startLogin() {
  const clientId = await getClientId();
  if (!clientId) throw new Error('No Client ID yet');
  const verifier = randomString(64);
  const state = randomString(16);
  sessionStorage.setItem('spotify:verifier', verifier);
  sessionStorage.setItem('spotify:state', state);
  const params = new URLSearchParams({
    client_id: clientId,
    response_type: 'code',
    redirect_uri: redirectUri(),
    code_challenge_method: 'S256',
    code_challenge: await sha256Base64Url(verifier),
    scope: SCOPES,
    state,
  });
  window.location.href = `https://accounts.spotify.com/authorize?${params}`;
}

async function requestToken(body: Record<string, string>): Promise<SavedAuth> {
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body),
  });
  if (!res.ok) throw new Error(`Spotify sign-in failed (${res.status})`);
  const data = await res.json();
  const auth: SavedAuth = {
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? body.refresh_token,
    expiresAt: Date.now() + (data.expires_in - 60) * 1000,
  };
  await setSetting(AUTH_KEY, auth);
  return auth;
}

// Step 3: if Spotify just sent us back with a code, swap it for keys.
// Returns an error message if something went wrong, otherwise null.
export async function finishLoginIfReturning(): Promise<string | null> {
  const params = new URLSearchParams(window.location.search);
  const code = params.get('code');
  const error = params.get('error');
  if (!code && !error) return null;
  // Clean the address bar (remove ?code=...), staying on the Spotify tab.
  window.history.replaceState(null, '', import.meta.env.BASE_URL + '#/spotify');
  if (error) return `Spotify said: ${error}`;
  if (params.get('state') !== sessionStorage.getItem('spotify:state')) return 'Sign-in check failed, try again.';
  const clientId = await getClientId();
  const verifier = sessionStorage.getItem('spotify:verifier');
  if (!clientId || !verifier) return 'Sign-in expired, try again.';
  try {
    await requestToken({
      grant_type: 'authorization_code',
      code: code!,
      redirect_uri: redirectUri(),
      client_id: clientId,
      code_verifier: verifier,
    });
    return null;
  } catch (e) {
    return (e as Error).message;
  }
}

// A working access key (refreshed automatically when it runs out).
export async function accessToken(): Promise<string> {
  const auth = await getSetting<SavedAuth>(AUTH_KEY);
  if (!auth) throw new Error('Not connected');
  if (Date.now() < auth.expiresAt) return auth.accessToken;
  const clientId = await getClientId();
  const fresh = await requestToken({
    grant_type: 'refresh_token',
    refresh_token: auth.refreshToken,
    client_id: clientId ?? '',
  });
  return fresh.accessToken;
}
