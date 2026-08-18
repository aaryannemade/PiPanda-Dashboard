import { Show } from "solid-js";
import type { Dashboard } from "../types";

interface PrinterHeaderProps {
  printer: Dashboard["printer"];
  online: boolean;
  connecting: boolean;
}

export function PrinterHeader(props: PrinterHeaderProps) {
  return (
    <header class="topbar">
      <div>
        <div class="printer-title-row">
          <h1>{props.printer.name || "Panda"}</h1>
          <Show when={props.printer.model}>
            <span class="model-pill">{props.printer.model}</span>
          </Show>
        </div>
        <div class="online-row" classList={{ offline: !props.online }}>
          <span class="online-dot" />
          <span>{props.online ? "Online" : props.connecting ? "Connecting" : "Offline"}</span>
        </div>
      </div>
    </header>
  );
}
