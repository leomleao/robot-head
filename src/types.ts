import type { CSSProperties, HTMLAttributes } from 'react';

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
  | 'determined'
  | 'attack'
  | 'defense'
  | 'peaceful'
  | 'asleep';

/**
 * Any other attribute (`className`, `style`, `onClick`, `aria-label`, …)
 * goes on the element: the `size` × `size` box the robot rests in. A `ref`
 * reaches the canvas inside it.
 */
export interface RobotHeadProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'color'> {
  /** What it is doing. Default `idle`. */
  state?: RobotHeadState;
  /** A face to wear over the state's own. */
  expression?: RobotExpression;
  /** The box the robot rests in, in px: head, neck and shoulders. Default `160`. */
  size?: number;
  /** Colour of the shell. Default a weathered gunmetal. */
  color?: string;
  /** Colour of the eyes' glow. Default a warm white. Defence and attack override it. */
  eyeColor?: string;
  /** Multiplier on every animation's speed. Default `1`. */
  speed?: number;
  /** Freeze every animation on its current frame. */
  paused?: boolean;
  /** Follow the pointer with the eyes and head, and react to a click. Default `true`. */
  interactive?: boolean;
  /** Draw the soft shadow the head casts on its collar. Default `true`. */
  floorShadow?: boolean;
  /** How open the jaw is, 0–1, for lip-sync from a level you already have. Replaces the procedural talking. */
  mouth?: number;
  /** 0–1, offsets the blinks and glances so a row of robots does not move in unison. */
  seed?: number;
  className?: string;
  style?: CSSProperties;
}
