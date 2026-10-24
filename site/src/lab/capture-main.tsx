/* The capture page: one paused robot from the query string, on a transparent
   page, for scripts/swift/capture-web-references.mjs to read pixels from.
   Dev-only like the rest of the lab: served at /src/lab/capture.html (the
   dev server redirects that to /src/lab/capture) and never part of the build.

   ?state=idle&expression=happy&size=240&color=%236b3f2e&eyeColor=%23bfe3ff&floorShadow=false */

import { useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { RobotHead, robotExpressions, robotHeadStates, type RobotExpression, type RobotHeadHandle, type RobotHeadState } from 'robot-heads';
import { frameFor, type Frame } from '../../../src/robot/render';

/* the references are always at 2× whatever screen captures them; set before the robot first reads it */
const DPR = 2;
Object.defineProperty(window, 'devicePixelRatio', { get: () => DPR, configurable: true });

const q = new URLSearchParams(location.search);
const params = {
  state: (q.get('state') ?? 'idle') as RobotHeadState,
  expression: (q.get('expression') || undefined) as RobotExpression | undefined,
  size: Number(q.get('size') ?? 240),
  color: q.get('color') || undefined,
  eyeColor: q.get('eyeColor') || undefined,
  floorShadow: q.get('floorShadow') !== 'false',
};

declare global {
  interface Window {
    capture?: {
      params: typeof params;
      states: RobotHeadState[];
      expressions: RobotExpression[];
      dpr: number;
      frame: Frame;
      canvas: HTMLCanvasElement;
      width: number;
      height: number;
      cssWidth: number;
      cssHeight: number;
    };
  }
}

function Capture() {
  const robot = useRef<RobotHeadHandle>(null);
  const f = frameFor(params.size);
  /* the robot paints its still in its own effect, which runs before this one */
  useEffect(() => {
    const canvas = robot.current!.canvas!;
    const r = canvas.getBoundingClientRect();
    window.capture = { params, states: robotHeadStates, expressions: robotExpressions, dpr: DPR, frame: f, canvas, width: canvas.width, height: canvas.height, cssWidth: r.width, cssHeight: r.height };
    document.body.dataset.ready = '1';
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  /* room around the box for the canvas that reaches past it */
  return (
    <div style={{ padding: `${f.padTop}px ${f.padSide}px ${f.padBottom}px`, width: 'max-content' }}>
      <RobotHead ref={robot} paused interactive={false} {...params} />
    </div>
  );
}

createRoot(document.getElementById('root')!).render(<Capture />);
