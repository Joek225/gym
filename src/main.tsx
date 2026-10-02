// Entry point: this is the first code that runs. It puts <App /> on the page.
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';

// Load the whiteboard's handwriting fonts from our own site (copied into public/fonts
// by "npm run copy-fonts") instead of an outside website.
(window as unknown as { EXCALIDRAW_ASSET_PATH: string }).EXCALIDRAW_ASSET_PATH = import.meta.env.BASE_URL;
import './styles.css';

// Coming back from Spotify's login page (".../gym/?code=..."): open the Spotify tab,
// which finishes signing in.
if (new URLSearchParams(window.location.search).has('code') || new URLSearchParams(window.location.search).has('error')) {
  window.location.hash = '/spotify';
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
