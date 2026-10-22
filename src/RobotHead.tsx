import { forwardRef, useEffect, useId, useImperativeHandle, useRef, type MouseEvent } from 'react';
import { listen, type AudioTap } from './audio';
import type { RobotExpression, RobotHeadHandle, RobotHeadProps, RobotHeadState } from './types';
import { RobotRenderer, frameFor, palette } from './robot/render';
import { EXPRESSIONS, EXPRESSION_NAMES, WHITE, type RGB } from './robot/rig';
import { REST, ROBOT_ACTIONS, RobotSim, targetFace, type ActionOptions, type RobotAction } from './robot/sim';
import { parseColor } from './color';
import { subscribe, pointer } from './ticker';

export const robotHeadStates: RobotHeadState[] = ['idle', 'thinking', 'searching', 'listening', 'speaking', 'working', 'happy', 'error', 'sleeping'];

export const robotExpressions: RobotExpression[] = EXPRESSION_NAMES;

export const robotActions: RobotAction[] = ROBOT_ACTIONS;

function hashSeed(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  return ((h >>> 0) % 1000) / 1000;
}

const reducedMotion = () =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

const SHELL: RGB = [60, 55, 63];

/* where a `lookAt` points, in page px: a point as given, or an element's middle */
function lookPoint(at: RobotHeadProps['lookAt']): { x: number; y: number } | null {
  if (!at) return null;
  const el = at instanceof Element ? at : 'current' in at ? at.current : null;
  if (el) {
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  return 'x' in at ? at : null;
}

/**
 * A heavy, gentle robot head: a dome with a crest, glowing eyes that do
 * the acting, and a hinged jaw that smiles and talks.
 *
 * The element is a `size` × `size` box with the head at rest filling it;
 * its canvas reaches past the box, so the head can tilt, the glow can
 * spill and the floor's shadow can sit below without taking part in layout.
 */
export const RobotHead = forwardRef<RobotHeadHandle, RobotHeadProps>(function RobotHead(
  {
    state = 'idle',
    expression,
    size = 160,
    color,
    eyeColor,
    speed = 1,
    paused = false,
    interactive = true,
    floorShadow = true,
    mouth,
    audio,
    lookAt,
    seed,
    className,
    style,
    onClick,
    'aria-label': ariaLabel,
    ...rest
  },
  ref
) {
  const boxRef = useRef<HTMLSpanElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const reactId = useId();
  const stateKey: RobotHeadState = robotHeadStates.includes(state) ? state : 'idle';
  const exprKey: RobotExpression | undefined = expression && expression in EXPRESSIONS ? expression : undefined;
  const seedValue = Math.min(1, Math.max(0, seed ?? hashSeed(reactId)));
  const still = paused || !(speed > 0);
  const shell = (color && parseColor(color)) || SHELL;
  const eye = (eyeColor && parseColor(eyeColor)) || WHITE;
  const shellKey = shell.join(',');
  const eyeKey = eye.join(',');

  const sim = useRef<RobotSim | null>(null);
  const renderer = useRef<RobotRenderer | null>(null);
  const pal = useRef(palette(shell));
  const palKey = useRef(shellKey);
  if (palKey.current !== shellKey) {
    palKey.current = shellKey;
    pal.current = palette(shell);
  }
  const stillRef = useRef(false);
  stillRef.current = still || reducedMotion();
  const speedRef = useRef(speed);
  speedRef.current = speed;
  const interactiveRef = useRef(interactive);
  interactiveRef.current = interactive;
  const shadowRef = useRef(floorShadow);
  shadowRef.current = floorShadow;
  const lookRef = useRef(lookAt);
  lookRef.current = lookAt;
  const mouthRef = useRef<number | null>(null);
  mouthRef.current = typeof mouth === 'number' && Number.isFinite(mouth) ? mouth : null;
  const tap = useRef<AudioTap | null>(null);

  /* listen to the audio, if any, for as long as it is given */
  useEffect(() => {
    if (!audio) return;
    let t: AudioTap | null = null;
    try {
      t = listen(audio);
    } catch (err) {
      /* an element already routed into another AudioContext can't be listened to; the jaw falls back to its own talking */
      console.warn('robot-heads: could not listen to this audio source', err);
      t = null;
    }
    tap.current = t;
    return () => {
      t?.stop();
      if (tap.current === t) tap.current = null;
    };
  }, [audio]);

  if (!sim.current) sim.current = new RobotSim(seedValue, stateKey, exprKey, eye);
  useImperativeHandle(ref, () => ({
    get canvas() {
      return canvasRef.current;
    },
    /* a still head has nothing to play it on: it resolves at once */
    play: (action: RobotAction, opts?: ActionOptions) => (stillRef.current ? Promise.resolve() : sim.current!.act(action, opts)),
  }), []);
  sim.current.set(stateKey, exprKey, eye);

  const frame = frameFor(size);
  const frameRef = useRef(frame);
  frameRef.current = frame;

  const paint = (animated: boolean) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const dpr = Math.min(2, (typeof devicePixelRatio === 'number' && devicePixelRatio) || 1);
    const f = frameRef.current;
    const w = Math.round((f.box + 2 * f.padSide) * dpr);
    const h = Math.round((f.box + f.padTop + f.padBottom) * dpr);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    if (!renderer.current) renderer.current = new RobotRenderer();
    const s = sim.current!;
    const face = animated ? s.face : targetFace(stateKey, exprKey, eye);
    renderer.current.draw(ctx, f, dpr, animated ? s.pose : REST[stateKey], face, pal.current, { shadow: shadowRef.current });
  };

  useEffect(() => {
    if (still || reducedMotion()) {
      paint(false);
      return;
    }
    return subscribe((dt) => {
      const s = sim.current!;
      const el = boxRef.current;
      /* points are measured from between the eyes at rest */
      let eyesX = 0, eyesY = 0;
      if (el) {
        const box = el.getBoundingClientRect();
        const f = frameRef.current;
        eyesX = box.left + box.width / 2;
        eyesY = box.top + f.cy - f.padTop - 0.26 * f.unit;
      }
      if (el && interactiveRef.current && Number.isFinite(pointer.x)) {
        const dx = pointer.x - eyesX, dy = pointer.y - eyesY;
        s.pointer = Math.hypot(dx, dy) < 900 ? { x: dx, y: dy } : null;
      } else s.pointer = null;
      const at = lookPoint(lookRef.current);
      s.lookAt = el && at ? { x: at.x - eyesX, y: at.y - eyesY } : null;
      s.mouth = mouthRef.current ?? (tap.current ? tap.current.level() : null);
      s.update(dt * speedRef.current);
      paint(true);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [still, size, stateKey, exprKey, shellKey, eyeKey, floorShadow]);

  const click = (e: MouseEvent<HTMLSpanElement>) => {
    if (interactive && !still) sim.current?.poke();
    onClick?.(e);
  };

  return (
    <span
      ref={boxRef}
      role="img"
      aria-label={ariaLabel ?? `Robot, ${stateKey}${exprKey ? `, ${exprKey}` : ''}`}
      className={className}
      onClick={click}
      style={{ position: 'relative', display: 'block', flex: 'none', width: size, height: size, cursor: interactive ? 'pointer' : undefined, ...style }}
      {...rest}
    >
      <canvas
        ref={canvasRef}
        aria-hidden
        style={{
          position: 'absolute',
          left: -frame.padSide,
          top: -frame.padTop,
          width: frame.box + 2 * frame.padSide,
          height: frame.box + frame.padTop + frame.padBottom,
          display: 'block',
          pointerEvents: 'none',
        }}
      />
    </span>
  );
});
