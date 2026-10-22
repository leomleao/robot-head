import type { CSSProperties, HTMLAttributes, RefObject } from 'react';
import type { RobotAudioSource } from './audio';

/** What the robot is doing: each state has its own motion and a face to go with it. */
export type RobotHeadState =
  | 'idle'
  | 'thinking'
  | 'searching'
  | 'listening'
  | 'speaking'
  | 'working'
  | 'happy'
  | 'error'
  | 'sleeping';

/** How the robot feels: a face that replaces the state's own, keeping the state's motion. */
export type RobotExpression =
  | 'neutral'
  | 'curious'
  | 'happy'
  | 'joyful'
  | 'sad'
  | 'sheepish'
  | 'sleepy'
  | 'suspicious'
  | 'content'
  | 'surprised'
  | 'afraid'
  | 'determined'
  | 'angry'
  | 'attack'
  | 'defense'
  | 'peaceful'
  | 'asleep';

/** Something the robot can be asked to do once, through its handle. */
export type { RobotAction, ActionOptions } from './robot/sim';
import type { ActionOptions, RobotAction } from './robot/sim';

/** What a `ref` on a robot reaches. */
export interface RobotHeadHandle {
  /** The canvas it draws on. */
  readonly canvas: HTMLCanvasElement | null;
  /**
   * Do something once, over whatever it is doing: `blink`, `nod`, `shake`,
   * `hmm`, `laugh`, `surprise`, `wake`, or `defense` (the eyes go red for
   * `hold` seconds and back). Resolves when it ends; a new action cuts the
   * last one short.
   */
  play(action: RobotAction, opts?: ActionOptions): Promise<void>;
}

/**
 * Any other attribute (`className`, `style`, `onClick`, `aria-label`, …)
 * goes on the element: the `size` × `size` box the robot rests in. A `ref`
 * reaches its handle.
 */
export interface RobotHeadProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'color'> {
  /** What it is doing. Default `idle`. */
  state?: RobotHeadState;
  /** A face to wear over the state's own. */
  expression?: RobotExpression;
  /** The box the head rests in, in px; tilts, the glow and the floor's shadow reach past it. Default `160`. */
  size?: number;
  /** Colour of the shell. Default a weathered gunmetal. */
  color?: string;
  /** Colour of the eyes' glow. Default a warm white. Angry and defense turn it red, attack pink. */
  eyeColor?: string;
  /** Multiplier on every animation's speed. Default `1`. */
  speed?: number;
  /** Freeze every animation on its current frame. */
  paused?: boolean;
  /** Follow the pointer with the eyes and head, and react to a click. Default `true`. */
  interactive?: boolean;
  /** Draw the soft shadow on the floor under the head. Default `true`. */
  floorShadow?: boolean;
  /** How open the jaw is, 0–1, for lip-sync from a level you already have. Replaces the procedural talking. */
  mouth?: number;
  /**
   * Sound to lip-sync to: a `MediaStream` (a microphone), an `<audio>` or
   * `<video>` element, or an `AudioNode` in your own graph. The jaw follows
   * its loudness. An element keeps playing through the speakers.
   */
  audio?: RobotAudioSource | null;
  /** Something to look at instead of the pointer: a point in viewport px, or an element (or a ref to one). */
  lookAt?: { x: number; y: number } | Element | RefObject<Element | null> | null;
  /** 0–1, offsets the blinks and glances so a row of robots does not move in unison. */
  seed?: number;
  className?: string;
  style?: CSSProperties;
}
