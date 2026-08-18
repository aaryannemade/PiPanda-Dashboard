import { Show } from "solid-js";
import type { Dashboard } from "../types";
import { Icon } from "./Icon";

interface CameraCardProps {
  camera: Dashboard["camera"];
  printerName: string;
  live: boolean;
  connecting: boolean;
}

function fittedPlayerUrl(url: string): string {
  const player = new URL(url, window.location.href);
  player.searchParams.set("width", "100%");
  return player.toString();
}

function fitEmbeddedPlayer(frame: HTMLIFrameElement): void {
  try {
    const document = frame.contentDocument;
    if (!document || document.getElementById("pipanda-camera-fit")) return;

    const style = document.createElement("style");
    style.id = "pipanda-camera-fit";
    style.textContent = `
      html, body {
        width: 100% !important;
        height: 100% !important;
        overflow: hidden !important;
      }
      body {
        display: block !important;
      }
      video-stream {
        display: block !important;
        width: 100% !important;
        height: 100% !important;
      }
      video-stream video {
        width: 100% !important;
        height: 100% !important;
        object-fit: cover !important;
      }
    `;
    document.head.append(style);
  } catch {
    // Direct go2rtc development URLs may be cross-origin and cannot be styled.
  }
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
              src={fittedPlayerUrl(url())}
              title={`${props.printerName} live camera`}
              allow="autoplay; fullscreen"
              loading="eager"
              onLoad={(event) => fitEmbeddedPlayer(event.currentTarget)}
            />
          )}
        </Show>
        <div class="live-chip" classList={{ inactive: !props.live }}>
          <span /> {props.live ? "LIVE" : "OFFLINE"}
        </div>
      </div>
    </article>
  );
}
