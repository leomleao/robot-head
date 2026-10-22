/* Lip-sync from live audio: one AudioContext for the page, made the first
   time a robot is given a source, and an analyser per source. The jaw
   follows the loudness of the sound (its RMS over about 20 ms), mapped so
   quiet room noise keeps the mouth shut and ordinary speech opens it most
   of the way; the robot's own springs smooth it into a jaw's motion. */

/** What a robot can listen to: a microphone or other stream, an `<audio>`/`<video>` element, or a node in your own audio graph. */
export type RobotAudioSource = MediaStream | HTMLMediaElement | AudioNode;

export interface AudioTap {
  /** How open the mouth should be now, 0–1. */
  level(): number;
  stop(): void;
}

let shared: AudioContext | null = null;
/* an element can be routed into an AudioContext only once, so its source node is kept */
const elementSources = new WeakMap<HTMLMediaElement, MediaElementAudioSourceNode>();

function context(): AudioContext | null {
  if (shared) return shared;
  const Ctx = typeof window !== 'undefined' ? window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext : undefined;
  if (!Ctx) return null;
  shared = new Ctx();
  /* browsers start it suspended until the page has been interacted with */
  if (shared.state === 'suspended') {
    const resume = () => {
      void shared?.resume();
      if (shared?.state === 'running') remove();
    };
    const remove = () => {
      window.removeEventListener('pointerdown', resume, true);
      window.removeEventListener('keydown', resume, true);
    };
    window.addEventListener('pointerdown', resume, true);
    window.addEventListener('keydown', resume, true);
  }
  return shared;
}

/** Start listening to a source; `level()` reads it on demand, so it costs nothing between frames. */
export function listen(source: RobotAudioSource): AudioTap | null {
  let ctx: BaseAudioContext | null;
  let input: AudioNode;
  let detach = () => {};
  if (source instanceof AudioNode) {
    /* a node lives in its own context: listen there */
    ctx = source.context;
    input = source;
  } else {
    ctx = context();
    if (!ctx) return null;
    if (source instanceof HTMLMediaElement) {
      let node = elementSources.get(source);
      if (!node) {
        node = (ctx as AudioContext).createMediaElementSource(source);
        /* routing an element into the graph takes it off the speakers: put it back */
        node.connect(ctx.destination);
        elementSources.set(source, node);
      }
      input = node;
      /* a paused element should not leave the context asleep when it plays */
      const wake = () => void (ctx as AudioContext).resume();
      source.addEventListener('play', wake);
      detach = () => source.removeEventListener('play', wake);
    } else {
      /* a stream (a microphone) only feeds the analyser, so it never echoes */
      const node = (ctx as AudioContext).createMediaStreamSource(source);
      input = node;
      const prev = detach;
      detach = () => {
        prev();
        node.disconnect();
      };
    }
  }
  const analyser = ctx.createAnalyser();
  analyser.fftSize = 1024;
  input.connect(analyser);
  const buf = new Float32Array(analyser.fftSize);
  return {
    level() {
      analyser.getFloatTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      const rms = Math.sqrt(sum / buf.length);
      /* a gate under quiet noise, and most of the way open at an ordinary speaking level */
      const t = Math.min(1, Math.max(0, (rms - 0.012) / 0.16));
      return Math.pow(t, 0.75);
    },
    stop() {
      try {
        input.disconnect(analyser);
      } catch {
        /* already disconnected */
      }
      detach();
    },
  };
}
