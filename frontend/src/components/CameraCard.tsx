import { Show } from "solid-js";
import type { Dashboard } from "../types";
import { Icon } from "./Icon";

interface CameraCardProps {
  camera: Dashboard["camera"];
  printerName: string;
  live: boolean;
  connecting: boolean;
}

export function CameraCard(props: CameraCardProps) {
  return (
    <article class="camera-panel">
      <div class="camera-frame">
        <Show
          when={props.camera.available && props.camera.player_url}
          fallback={
            <div class="camera-placeholder">
              <div class="camera-grid" />
              <Icon name="camera" size={34} />
              <strong>{props.connecting ? "Waiting for camera" : "Camera unavailable"}</strong>
              <span>Pi Camera Module 3 · {props.camera.stream_name}</span>
            </div>
          }
        >
          {(url) => (
            <iframe
              src={url() ?? undefined}
              title={`${props.printerName} live camera`}
              allow="autoplay; fullscreen"
              loading="eager"
            />
          )}
        </Show>
        <div class="live-chip" classList={{ inactive: !props.live }}>
          <span /> {props.live ? "LIVE" : "OFFLINE"}
        </div>
      </div>
      <div class="pager-dots" aria-hidden="true"><span /><span class="active" /></div>
    </article>
  );
}
