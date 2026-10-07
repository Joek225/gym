// Small preview pictures of slideshow pages (for the strip along the bottom and the list).
import { exportToSvg } from '@excalidraw/excalidraw';

// A page's drawing → an SVG picture (as text), or null for an empty page.
export async function pagePreview(data: any): Promise<string | null> {
  const elements = (data?.elements ?? [])
    .filter((el: any) => !el.isDeleted)
    // Videos show as a solid dark box (instead of their web address).
    .map((el: any) =>
      el.type === 'embeddable'
        ? { ...el, type: 'rectangle', link: null, fillStyle: 'solid', backgroundColor: '#e3e3e3', roughness: 0 }
        : el,
    );
  if (elements.length === 0) return null;
  const svg = await exportToSvg({
    elements,
    appState: {
      exportBackground: true,
      viewBackgroundColor: data?.appState?.viewBackgroundColor ?? '#dfe2f1',
      exportWithDarkMode: true, // same dark look as on screen
      exportPadding: 24,
    } as any,
    files: data?.files ?? null,
    skipInliningFonts: true, // fonts come from the site itself; keeps previews small
  } as any);
  svg.removeAttribute('width');
  svg.removeAttribute('height');
  return new XMLSerializer().serializeToString(svg);
}

export const svgUrl = (svg: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
