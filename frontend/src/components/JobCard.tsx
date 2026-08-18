import { Show, createMemo } from "solid-js";
import type { Dashboard } from "../types";
import { Icon } from "./Icon";

interface JobCardProps {
  job: Dashboard["job"];
}

function formatDuration(minutes: number | null): string | null {
  if (minutes == null) return null;
  if (minutes < 60) return `${minutes} min remaining`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return `${hours}h ${rest}m remaining`;
}

function friendlyState(state: string | null, result: Dashboard["job"]["result"]): string {
  if (result === "success") return "Success";
  if (result === "failed") return "Failed";
  switch (state) {
    case "RUNNING": return "Printing";
    case "PAUSE": return "Paused";
    case "PREPARE": return "Preparing";
    case "FINISH": return "Complete";
    case "IDLE": return "Ready";
    default: return "No active print";
  }
}

export function JobCard(props: JobCardProps) {
  const progress = createMemo(() => Math.max(0, Math.min(100, props.job.progress_percent ?? 0)));

  return (
    <article class="job-card panel">
      <div class="job-main">
        <div class="print-preview">
          <Show when={props.job.thumbnail_url} fallback={<div class="preview-model"><Icon name="cube" size={48} /></div>}>
            {(url) => <img src={url()} alt="Print preview" />}
          </Show>
        </div>
        <div class="job-copy">
          <p class="eyebrow">Current print</p>
          <h2>{props.job.name ?? "No active print"}</h2>
          <p class="job-profile">{props.job.profile ?? formatDuration(props.job.remaining_minutes) ?? "Printer is ready"}</p>
          <div class="job-status-line">
            <strong>{props.job.progress_percent == null ? "—" : `${progress()}%`}</strong>
            <span classList={{ success: props.job.result === "success", failed: props.job.result === "failed" }}>
              {friendlyState(props.job.state, props.job.result)}
            </span>
          </div>
          <div class="progress-track" role="progressbar" aria-label="Print progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow={progress()}>
            <span style={{ width: `${progress()}%` }} />
          </div>
          <p class="layer-copy">Layer {props.job.layer ?? "—"}/{props.job.total_layers ?? "—"}</p>
        </div>
      </div>
    </article>
  );
}
