import { forwardRef, useEffect, useId, useImperativeHandle, useRef, type MouseEvent } from 'react';
import type { RobotExpression, RobotHeadProps, RobotHeadState } from './types';
import { RobotRenderer, REST_POSE, frameFor, palette } from './robot/render';
import { EXPRESSIONS, EXPRESSION_NAMES, WHITE, type RGB } from './robot/rig';
import { RobotSim, targetFace } from './robot/sim';
import { parseColor } from './color';
import { subscribe, pointer } from './ticker';

export const robotHeadStates: RobotHeadState[] = ['idle', 'thinking', 'searching', 'listening', 'speaking', 'working', 'happy', 'error', 'sleeping'];

export const robotExpressions: RobotExpression[] = EXPRESSION_NAMES;

function hashSeed(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  return ((h >>> 0) % 1000) / 1000;
}

const reducedMotion = () =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

const SHELL: RGB = [66, 62, 60];

/**
 * A heavy, gentle robot: a domed head on a neck between broad shoulders,
 * with glowing eyes that do the acting and a jaw that smiles and talks.
 *
 * The element is a `size` × `size` box with the robot at rest filling it;
 * its canvas reaches past the box, so the head can tilt and the glow can
 * spill without taking part in layout.
 */
export const RobotHead = forwardRef<HTMLCanvasElement, RobotHeadProps>(function RobotHead(
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
  useImperativeHandle(ref, () => canvasRef.current as HTMLCanvasElement);
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
  const speedRef = useRef(speed);
  speedRef.current = speed;
  const interactiveRef = useRef(interactive);
  interactiveRef.current = interactive;
  const shadowRef = useRef(floorShadow);
  shadowRef.current = floorShadow;

  if (!sim.current) sim.current = new RobotSim(seedValue, stateKey, exprKey, eye);
  sim.current.set(stateKey, exprKey, eye);
  sim.current.mouth = typeof mouth === 'number' && Number.isFinite(mouth) ? mouth : null;

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
    renderer.current.draw(ctx, f, dpr, animated ? s.pose : REST_POSE, face, pal.current, { shadow: shadowRef.current });
  };

  useEffect(() => {
    if (still || reducedMotion()) {
      paint(false);
      return;
    }
    return subscribe((dt) => {
      const s = sim.current!;
      const el = boxRef.current;
      if (el && interactiveRef.current && Number.isFinite(pointer.x)) {
        /* measured from between the eyes at rest */
        const box = el.getBoundingClientRect();
        const f = frameRef.current;
        const dx = pointer.x - (box.left + box.width / 2);
        const dy = pointer.y - (box.top + f.cy - f.padTop - 0.27 * f.unit);
        s.pointer = Math.hypot(dx, dy) < 900 ? { x: dx, y: dy } : null;
      } else s.pointer = null;
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
