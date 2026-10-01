import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // The site lives at https://joek225.github.io/gym/, so every file path starts with /gym/.
  base: '/gym/',
});
