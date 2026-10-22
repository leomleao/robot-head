import { useEffect, useRef, useState } from 'react';
import { RobotHead, robotActions, robotExpressions, robotHeadStates, type RobotAction, type RobotExpression, type RobotHeadHandle, type RobotHeadState } from 'robot-heads';

/* ?state=thinking&expression=happy&paused for screenshots */
const q = new URLSearchParams(location.search);

/* what each state does, in his own words and then in ours */
const stateHints: Record<RobotHeadState, [string, string]> = {
  idle: ['Hmm.', 'Slow glances, slow blinks, the odd tilt of the head.'],
  thinking: ['Hmm?', 'Looking up, to one side and then the other.'],
  searching: ['Rockwell?', 'A slow sweep, the eyes a step ahead of the head.'],
  listening: ['Mm-hmm.', 'Head cocked toward you, nodding along.'],
  speaking: ['You stay. I go.', 'Short words, a pause between. Give it audio to lip-sync.'],
  working: ['I fix.', 'Eyes down on the work, careful.'],
  happy: ['Rockwell!', 'A hop, a grin, a sway.'],
  error: ['Awww.', 'A slow shake of the head. Never red: red is for danger.'],
  sleeping: ['…', 'Shut down and breathing. Wake it to watch the eyes come back.'],
};

const actionHints: Record<RobotAction, string> = {
  blink: 'Blink',
  nod: 'Nod',
  shake: 'Shake',
  hmm: 'Hmm?',
  laugh: 'Laugh',
  surprise: 'Surprise',
  wake: 'Wake',
  defense: 'Defense',
};

interface Colors {
  color: string;
  eyeColor: string;
}

const DEFAULTS: Colors = { color: '#3c373f', eyeColor: '#ffece2' };

const SWATCHES: Record<keyof Colors, Array<[string, string]>> = {
  color: [
    ['Gunmetal', '#3c373f'],
    ['Iron', '#4a4744'],
    ['Rust', '#6b3f2e'],
    ['Bronze', '#7a5a3a'],
    ['Navy', '#2c3550'],
    ['Moss', '#3d4a35'],
    ['Ash', '#8a8580'],
  ],
  eyeColor: [
    ['Warm', '#ffece2'],
    ['Amber', '#ffb347'],
    ['Moonlight', '#bfe3ff'],
    ['Mint', '#c8ffd9'],
  ],
};

const ROW_LABELS: Record<keyof Colors, string> = { color: 'Shell', eyeColor: 'Eyes' };
const SPEEDS = [0.5, 1, 1.5, 2];

const title = (s: string) => s[0].toUpperCase() + s.slice(1);

/* the stage head fills the room it is given, within reason */
function useStageSize() {
  const measure = () => {
    const w = window.innerWidth, h = window.innerHeight;
    if (w < 900) return Math.max(160, Math.min(w - 96, 260));
    /* centred on the screen, so it keeps the controls' width clear on both sides */
    const room = Math.min(w - 2 * (300 + 40 + 40), h - 300);
    return Math.round(Math.max(170, Math.min(room * 0.62, 320)));
  };
  const [size, setSize] = useState(measure);
  useEffect(() => {
    const on = () => setSize(measure());
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return size;
}

/* frames per second, measured over the last second */
function useFps() {
  const [fps, setFps] = useState(0);
  useEffect(() => {
    let raf = 0, frames = 0, since = performance.now();
    const tick = (now: number) => {
      frames++;
      if (now - since >= 1000) {
        setFps(Math.round((frames * 1000) / (now - since)));
        frames = 0;
        since = now;
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);
  return fps;
}

function Dock({ onPlay, playing }: { onPlay: (a: RobotAction) => void; playing: RobotAction | null }) {
  return (
    <nav className="dock" aria-label="Actions">
      {robotActions.map((a) => (
        <button key={a} className="dock-item" aria-pressed={a === playing} onClick={() => onPlay(a)}>
          {actionHints[a]}
        </button>
      ))}
    </nav>
  );
}

function Swatches({ name, value, onChange }: { name: keyof Colors; value: string; onChange: (v: string) => void }) {
  const known = SWATCHES[name].find(([, hex]) => hex === value);
  return (
    <div className="control">
      <div className="control-head">
        <span className="control-label">{ROW_LABELS[name]}</span>
        <span className="control-value">{known ? known[0] : value}</span>
      </div>
      <div className="swatches">
        {SWATCHES[name].map(([label, hex]) => (
          <button
            key={hex}
            className="swatch"
            style={{ background: hex }}
            title={label}
            aria-label={`${ROW_LABELS[name]}: ${label}`}
            aria-pressed={hex === value}
            onClick={() => onChange(hex)}
          />
        ))}
        <label className="swatch swatch-custom" title="Custom" aria-pressed={!known} style={known ? undefined : { background: value }}>
          <input type="color" value={value} aria-label={`${ROW_LABELS[name]}: custom colour`} onChange={(e) => onChange(e.target.value)} />
        </label>
      </div>
    </div>
  );
}

type Theme = 'dark' | 'light';

function useTheme() {
  const [theme, setTheme] = useState<Theme>(() => (document.documentElement.dataset.theme === 'light' ? 'light' : 'dark'));
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);
  const toggle = () => {
    const next: Theme = theme === 'dark' ? 'light' : 'dark';
    setTheme(next);
    try {
      localStorage.setItem('robot-heads-theme', next);
    } catch {
      /* private mode: the choice lasts the visit */
    }
  };
  return [theme, toggle] as const;
}

function ThemeToggle({ theme, onToggle }: { theme: Theme; onToggle: () => void }) {
  const light = theme === 'light';
  return (
    <button className="theme" onClick={onToggle} aria-label={light ? 'Switch to dark mode' : 'Switch to light mode'} title={light ? 'Dark mode' : 'Light mode'}>
      {light ? (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
          <path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z" />
        </svg>
      ) : (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden>
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
        </svg>
      )}
    </button>
  );
}

interface PropLine {
  key: string;
  /* the prop's name and value; strings are quoted, anything else goes in braces */
  name: string;
  value: string | number | boolean;
  on: boolean;
}

const propText = (l: PropLine) => (typeof l.value === 'string' ? `${l.name}="${l.value}"` : `${l.name}={${l.value}}`);

/* one prop, coloured like GitHub's own theme */
function PropTokens({ line }: { line: PropLine }) {
  return (
    <>
      <span className="tok-attr">{line.name}</span>
      <span className="tok-punct">=</span>
      {typeof line.value === 'string' ? (
        <span className="tok-string">"{line.value}"</span>
      ) : (
        <>
          <span className="tok-punct">{'{'}</span>
          <span className="tok-number">{String(line.value)}</span>
          <span className="tok-punct">{'}'}</span>
        </>
      )}
    </>
  );
}

/* the snippet, one line per prop; a prop line opens and closes on its own,
   so the block grows a line at a time instead of jumping */
function Snippet({ lines }: { lines: PropLine[] }) {
  /* a closing line keeps its last value while it folds away: each open
     line's value is remembered as it renders (React's way of adjusting
     state from props, no effect needed) */
  const [last, setLast] = useState<Record<string, PropLine>>({});
  const stale = lines.filter((l) => l.on && last[l.key]?.value !== l.value);
  if (stale.length) setLast({ ...last, ...Object.fromEntries(stale.map((l) => [l.key, l])) });
  return (
    <pre className="code">
      <code>
        <span className="code-line">
          <span className="tok-punct">{'<'}</span>
          <span className="tok-tag">RobotHead</span>
        </span>
        {lines.map((l) => (
          <span key={l.key} className="code-prop" data-open={l.on}>
            <span className="code-prop-inner">
              {'  '}
              <PropTokens line={l.on ? l : last[l.key] ?? l} />
            </span>
          </span>
        ))}
        <span className="code-line tok-punct">{'/>'}</span>
      </code>
    </pre>
  );
}

function useCopy() {
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (key: string, text: string) =>
    navigator.clipboard?.writeText(text).then(() => {
      setCopied(key);
      setTimeout(() => setCopied(null), 1400);
    }, () => {});
  return [copied, copy] as const;
}

/* the microphone, on demand */
function useMicrophone() {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [error, setError] = useState('');
  const toggle = async () => {
    if (stream) {
      stream.getTracks().forEach((t) => t.stop());
      setStream(null);
      return;
    }
    try {
      setError('');
      setStream(await navigator.mediaDevices.getUserMedia({ audio: true }));
    } catch {
      setError('No microphone');
    }
  };
  useEffect(() => () => stream?.getTracks().forEach((t) => t.stop()), [stream]);
  return [stream, toggle, error] as const;
}

export default function App() {
  const [state, setState] = useState<RobotHeadState>((q.get('state') as RobotHeadState) ?? 'idle');
  const [expression, setExpression] = useState<RobotExpression | null>((q.get('expression') as RobotExpression) ?? null);
  const [colors, setColors] = useState<Colors>(DEFAULTS);
  const [speed, setSpeed] = useState(1);
  const [paused, setPaused] = useState(q.has('paused'));
  const [lookAtCode, setLookAtCode] = useState(false);
  const [playing, setPlaying] = useState<RobotAction | null>(null);
  const [mic, toggleMic, micError] = useMicrophone();
  const [copied, copy] = useCopy();
  const [theme, toggleTheme] = useTheme();
  const fps = useFps();
  const size = useStageSize();
  const robot = useRef<RobotHeadHandle>(null);
  const code = useRef<HTMLDivElement>(null);

  const play = (a: RobotAction) => {
    setPlaying(a);
    void robot.current?.play(a).then(() => setPlaying((p) => (p === a ? null : p)));
  };
  const micOn = async () => {
    await toggleMic();
    if (!mic) setState('speaking');
  };

  const changed = colors.color !== DEFAULTS.color || colors.eyeColor !== DEFAULTS.eyeColor || speed !== 1 || paused || expression !== null || lookAtCode;
  const lines: PropLine[] = [
    { key: 'state', name: 'state', value: state, on: true },
    { key: 'expression', name: 'expression', value: expression ?? '', on: expression !== null },
    { key: 'color', name: 'color', value: colors.color, on: colors.color !== DEFAULTS.color },
    { key: 'eyeColor', name: 'eyeColor', value: colors.eyeColor, on: colors.eyeColor !== DEFAULTS.eyeColor },
    { key: 'speed', name: 'speed', value: speed, on: speed !== 1 },
    { key: 'audio', name: 'audio', value: 'microphone', on: !!mic },
  ];
  const snippet = `<RobotHead\n${lines.filter((l) => l.on).map((l) => `  ${propText(l)}\n`).join('')}/>`;
  const [said, what] = stateHints[state];

  return (
    <div className="app">
      <Dock onPlay={play} playing={playing} />

      <header className="masthead">
        <div className="byline">
          <span className="name">robot-heads</span>
          <span className="by">a heavy, gentle robot for your UI</span>
        </div>
        <div className="masthead-end">
          <a className="icon-link" href="https://github.com/leomleao/robot-head" target="_blank" rel="noopener noreferrer" aria-label="Source on GitHub" title="GitHub">
            {/* Icon from Material Design Icons by Pictogrammers - https://github.com/Templarian/MaterialDesign/blob/master/LICENSE */}
            <svg viewBox="0 0 24 24" aria-hidden>
              <path fill="currentColor" d="M12 2A10 10 0 0 0 2 12c0 4.42 2.87 8.17 6.84 9.5c.5.08.66-.23.66-.5v-1.69c-2.77.6-3.36-1.34-3.36-1.34c-.46-1.16-1.11-1.47-1.11-1.47c-.91-.62.07-.6.07-.6c1 .07 1.53 1.03 1.53 1.03c.87 1.52 2.34 1.07 2.91.83c.09-.65.35-1.09.63-1.34c-2.22-.25-4.55-1.11-4.55-4.92c0-1.11.38-2 1.03-2.71c-.1-.25-.45-1.29.1-2.64c0 0 .84-.27 2.75 1.02c.79-.22 1.65-.33 2.5-.33s1.71.11 2.5.33c1.91-1.29 2.75-1.02 2.75-1.02c.55 1.35.2 2.39.1 2.64c.65.71 1.03 1.6 1.03 2.71c0 3.82-2.34 4.66-4.57 4.91c.36.31.69.92.69 1.85V21c0 .27.16.59.67.5C19.14 20.16 22 16.42 22 12A10 10 0 0 0 12 2" />
            </svg>
          </a>
          <ThemeToggle theme={theme} onToggle={toggleTheme} />
        </div>
      </header>

      <main className="stage" aria-label="Preview">
        <RobotHead
          ref={robot}
          state={state}
          expression={expression ?? undefined}
          size={size}
          paused={paused}
          speed={speed}
          audio={mic}
          lookAt={lookAtCode ? code : null}
          {...colors}
        />
        <div className="caption">
          <h1 className="font-bold">{expression ? title(expression) : title(state)}</h1>
          <p>
            <span className="said">“{said}”</span> {what}
          </p>
        </div>
      </main>

      <aside className="controls" aria-label="Controls">
        {(Object.keys(SWATCHES) as Array<keyof Colors>).map((key) => (
          <Swatches key={key} name={key} value={colors[key]} onChange={(v) => setColors((c) => ({ ...c, [key]: v }))} />
        ))}

        <div className="control">
          <div className="control-head">
            <span className="control-label">Expression</span>
            <span className="control-value">{expression ?? `the state's own`}</span>
          </div>
          <div className="chips" role="group" aria-label="Expression">
            <button className="chip" aria-pressed={expression === null} onClick={() => setExpression(null)}>auto</button>
            {robotExpressions.map((e) => (
              <button key={e} className="chip" aria-pressed={e === expression} onClick={() => setExpression(e)}>
                {e}
              </button>
            ))}
          </div>
        </div>

        <div className="control">
          <div className="control-head">
            <span className="control-label">Lip-sync and gaze</span>
            <span className="control-value">{micError}</span>
          </div>
          <div className="segments" role="group" aria-label="Lip-sync and gaze">
            <button className="segment" aria-pressed={!!mic} onClick={() => void micOn()}>
              {mic ? 'Mic on' : 'Microphone'}
            </button>
            <button className="segment" aria-pressed={lookAtCode} onClick={() => setLookAtCode(!lookAtCode)}>
              {lookAtCode ? 'Watching code' : 'Look at code'}
            </button>
          </div>
        </div>

        <div className="control">
          <div className="control-head">
            <span className="control-label">Speed</span>
            <span className="control-actions">
              <span className="control-value">{fps ? `${fps} fps` : ''}</span>
              <button className="text-button" onClick={() => setPaused(!paused)}>{paused ? 'Play' : 'Pause'}</button>
            </span>
          </div>
          <div className="segments" role="group" aria-label="Speed">
            {SPEEDS.map((v) => (
              <button key={v} className="segment" aria-pressed={v === speed} onClick={() => setSpeed(v)}>
                {v}×
              </button>
            ))}
          </div>
        </div>

        <div className="control" ref={code}>
          <div className="control-head">
            <span className="control-label">Usage</span>
            <span className="control-actions">
              <button
                className="text-button reset"
                aria-hidden={!changed}
                tabIndex={changed ? 0 : -1}
                onClick={() => {
                  setColors(DEFAULTS);
                  setSpeed(1);
                  setPaused(false);
                  setExpression(null);
                  setLookAtCode(false);
                }}
              >
                Reset
              </button>
              <button className="text-button" onClick={() => copy('snippet', snippet)}>{copied === 'snippet' ? 'Copied' : 'Copy'}</button>
            </span>
          </div>
          <Snippet lines={lines} />
        </div>
      </aside>

      <nav className="states" aria-label="State">
        {robotHeadStates.map((s) => (
          <button key={s} className="state" aria-pressed={s === state} onClick={() => setState(s)}>
            <span className="state-head">
              <RobotHead state={s} size={64} paused={paused} speed={speed} interactive={false} floorShadow={false} aria-hidden {...colors} />
            </span>
            <span className="state-name">{title(s)}</span>
          </button>
        ))}
      </nav>

      <footer className="credits">
        Head adapted from a sculpt by <a href="https://www.printables.com/model/212558" target="_blank" rel="noopener noreferrer">EMA Labs</a> (
        <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noopener noreferrer">CC BY 4.0</a>) · forked from{' '}
        <a href="https://github.com/fayazara/robot-heads" target="_blank" rel="noopener noreferrer">robot-heads</a> by Fayaz Ahmed (MIT)
      </footer>
    </div>
  );
}
