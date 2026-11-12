/// Isolated-world video PiP operations. Session ownership is cleared by the native leave event,
/// so a later manual request, even for the same element, cannot be closed on tab selection.
package enum BrowserAutomaticPiPScript {
    private static let candidate = #"""
    (() => {
      if (!document.pictureInPictureEnabled || document.pictureInPictureElement ||
          !navigator.userActivation.hasBeenActive) return null;
      const videos = [...document.querySelectorAll('video')].filter(v =>
        !v.muted && v.volume > 0 &&
        (v.webkitAudioDecodedByteCount > 0 ||
         [...(v.srcObject?.getAudioTracks?.() ?? [])].some(t => t.enabled && t.readyState === "live")) &&
        !v.paused && !v.ended && v.readyState >= 2 && v.videoWidth > 0 && !v.disablePictureInPicture &&
        v.checkVisibility({checkOpacity:true, checkVisibilityCSS:true}) && (() => {
          const r = v.getBoundingClientRect();
          return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 &&
                 r.top < innerHeight && r.left < innerWidth;
        })());
      videos.sort((a,b) => b.videoWidth*b.videoHeight - a.videoWidth*a.videoHeight);
      return videos[0] ?? null;
    })()
    """#

    /// Evaluate without a synthetic user gesture before requesting PiP.
    package static let isEligible = "Boolean(\(candidate))"

    package static let enter = """
    (async () => {
      const video = \(candidate);
      if (!video) return false;
      const session = {video};
      const clear = () => {
        if (globalThis.orbitAutomaticPiP === session) delete globalThis.orbitAutomaticPiP;
      };
      video.addEventListener('leavepictureinpicture', clear, {once:true});
      globalThis.orbitAutomaticPiP = session;
      try {
        await video.requestPictureInPicture();
        if (session.cancelled && document.pictureInPictureElement === video) {
          await document.exitPictureInPicture();
          clear();
          return false;
        }
        if (document.pictureInPictureElement === video && globalThis.orbitAutomaticPiP === session) return true;
      } catch (_) {}
      clear();
      video.removeEventListener('leavepictureinpicture', clear);
      return false;
    })()
    """

    package static let endSession = #"""
    (() => {
      const session = globalThis.orbitAutomaticPiP;
      if (session) session.cancelled = true;
      if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
    })()
    """#

    package static let returnToSource = #"""
    (async () => {
      const session = globalThis.orbitAutomaticPiP;
      if (!session || document.pictureInPictureElement !== session.video) return false;
      try {
        await document.exitPictureInPicture();
        return true;
      } catch (_) { return false; }
    })()
    """#
}
