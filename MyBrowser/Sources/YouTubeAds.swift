import WebKit

/// YouTube's video ads come from the same servers as the videos, so a blocklist can't stop
/// them. Instead, on youtube.com only, this mutes an ad the moment it starts, jumps it to the
/// end and presses "Skip", so it's gone in a fraction of a second. It also hides the banner
/// and sidebar ads. Settings → Skip YouTube ads turns it off.
@MainActor
enum YouTubeAds {
    static func install(in controller: WKUserContentController) {
        guard Preferences.skipYouTubeAds else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    private static let script = #"""
    (() => {
      if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
      // Banner, overlay and sidebar ads: hidden.
      const css = `ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-promoted-sparkles-web-renderer,
        ytd-display-ad-renderer, ytd-companion-slot-renderer, ytd-action-companion-ad-renderer,
        ytd-player-legacy-desktop-watch-ads-renderer, #player-ads, #masthead-ad, .ytp-ad-overlay-container,
        ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-rich-item-renderer:has(ytd-ad-slot-renderer)
        { display: none !important; }`;
      const addStyle = () => {
        if (document.getElementById('bb-yt-ads')) return;
        const s = document.createElement('style'); s.id = 'bb-yt-ads'; s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      addStyle(); document.addEventListener('DOMContentLoaded', addStyle);
      // Video ads: mute, jump to the end, press Skip.
      let muted = false;
      const tick = () => {
        const player = document.querySelector('.html5-video-player');
        const video = document.querySelector('video.html5-main-video') || document.querySelector('#movie_player video');
        const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, button[class*="skip-ad"]');
        if (skip) skip.click();
        if (player && video && player.classList.contains('ad-showing')) {
          if (!video.muted) { video.muted = true; muted = true; }
          if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
            video.currentTime = video.duration - 0.05;
          }
          video.playbackRate = 16;
        } else if (video && muted) {
          video.muted = false; muted = false;
          if (video.playbackRate > 2) video.playbackRate = 1;
        }
      };
      setInterval(tick, 300);
    })();
    """#
}
