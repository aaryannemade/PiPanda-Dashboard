import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import type { PrintAction, SpeedLevel } from "../types";
import { Icon } from "./Icon";

export type PrintCommand = { kind: PrintAction } | { kind: "speed"; level: SpeedLevel };

interface PrintControlsProps {
  state: string | null;
  speedLevel: SpeedLevel | null;
  available: boolean;
  pending: PrintCommand | undefined;
  onCommand: (command: PrintCommand) => void;
}

const SPEED_LEVELS: { level: SpeedLevel; label: string; percent: number }[] = [
  { level: "silent", label: "Silent", percent: 50 },
  { level: "standard", label: "Standard", percent: 100 },
  { level: "sport", label: "Sport", percent: 124 },
  { level: "ludicrous", label: "Ludicrous", percent: 166 },
];

/** How long the stop button waits for its second tap before backing out. */
const STOP_CONFIRM_MS = 4_000;

export function PrintControls(props: PrintControlsProps) {
  const [confirmingStop, setConfirmingStop] = createSignal(false);
  const [speedOpen, setSpeedOpen] = createSignal(false);
  let stopTimer: number | undefined;

  const active = createMemo(() => props.state === "RUNNING" || props.state === "PAUSE" || props.state === "PREPARE");
  const paused = createMemo(() => props.state === "PAUSE");
  const busy = createMemo(() => !props.available || props.pending != null);
  const speed = createMemo(() => SPEED_LEVELS.find((entry) => entry.level === props.speedLevel));
  const pendingKind = createMemo(() => props.pending?.kind);

  const resetStop = () => {
    if (stopTimer != null) window.clearTimeout(stopTimer);
    stopTimer = undefined;
    setConfirmingStop(false);
  };

  // A job that ends by itself must not leave a stale confirmation or menu.
  createEffect(() => {
    if (!active()) {
      resetStop();
      setSpeedOpen(false);
    }
  });
  onCleanup(resetStop);

  const stop = () => {
    if (!confirmingStop()) {
      setSpeedOpen(false);
      setConfirmingStop(true);
      stopTimer = window.setTimeout(resetStop, STOP_CONFIRM_MS);
      return;
    }
    resetStop();
    props.onCommand({ kind: "stop" });
  };

  const togglePause = () => {
    resetStop();
    props.onCommand({ kind: paused() ? "resume" : "pause" });
  };

  const chooseSpeed = (level: SpeedLevel) => {
    setSpeedOpen(false);
    if (level !== props.speedLevel) props.onCommand({ kind: "speed", level });
  };

  return (
    <article class="print-card panel">
      <div class="print-actions">
        <button
          type="button"
          class="print-action stop"
          classList={{ confirming: confirmingStop(), pending: pendingKind() === "stop" }}
          disabled={!active() || busy()}
          aria-label={confirmingStop() ? "Confirm stopping the print" : "Stop print"}
          onClick={stop}
        >
          <Icon name="stop" size={22} />
          <span>{confirmingStop() ? "Tap to confirm" : "Stop"}</span>
        </button>

        <button
          type="button"
          class="print-action"
          classList={{ resume: paused(), pause: !paused(), pending: pendingKind() === "pause" || pendingKind() === "resume" }}
          disabled={!active() || props.state === "PREPARE" || busy()}
          aria-label={paused() ? "Resume print" : "Pause print"}
          onClick={togglePause}
        >
          <Icon name={paused() ? "play" : "pause"} size={22} />
          <span>{paused() ? "Resume" : "Pause"}</span>
        </button>

        <button
          type="button"
          class="print-action speed"
          classList={{ open: speedOpen(), pending: pendingKind() === "speed" }}
          disabled={!active() || busy()}
          aria-expanded={speedOpen()}
          aria-label="Print speed"
          onClick={() => {
            resetStop();
            setSpeedOpen(!speedOpen());
          }}
        >
          <Icon name="gauge" size={22} />
          <span>{speed()?.label ?? "Speed"}</span>
        </button>
      </div>

      <Show when={speedOpen()}>
        <div class="speed-options" role="radiogroup" aria-label="Print speed">
          <For each={SPEED_LEVELS}>{(entry) => (
            <button
              type="button"
              role="radio"
              aria-checked={entry.level === props.speedLevel}
              classList={{ selected: entry.level === props.speedLevel }}
              onClick={() => chooseSpeed(entry.level)}
            >
              <strong>{entry.label}</strong>
              <span>{entry.percent}%</span>
            </button>
          )}</For>
        </div>
      </Show>
    </article>
  );
}
