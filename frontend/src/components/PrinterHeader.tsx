import { Show } from "solid-js";
import type { Dashboard } from "../types";
import { Icon } from "./Icon";

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
          <span class="selector-mark" aria-hidden="true" />
          <Show when={props.printer.model}>
            <span class="model-pill">{props.printer.model}</span>
          </Show>
        </div>
        <div class="online-row" classList={{ offline: !props.online }}>
          <span class="online-dot" />
          <span>{props.online ? "Online" : props.connecting ? "Connecting" : "Offline"}</span>
        </div>
      </div>
      <div class="header-actions">
        <button class="icon-button" type="button" aria-label="Printer settings unavailable" disabled>
          <Icon name="settings" size={25} />
        </button>
        <button class="icon-button" type="button" aria-label="Printer scanner unavailable" disabled>
          <Icon name="scan" size={27} />
        </button>
      </div>
    </header>
  );
}
