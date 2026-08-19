import type { Dashboard } from "../types";
import type { HomeAssistantGroup } from "../types";
import { Icon } from "./Icon";

interface DeviceControlsProps {
  controls: Dashboard["controls"];
  lightControlAvailable: boolean;
  lightOn: boolean;
  lightPending: boolean;
  onToggleLight: () => void;
  onOpenHomeAssistant: (group: HomeAssistantGroup) => void;
}

function measurement(value: number | null, suffix = ""): string {
  return value == null ? "—" : `${Math.round(value)}${suffix}`;
}

export function DeviceControls(props: DeviceControlsProps) {
  return (
    <section class="content-section controls-section">
      <div class="section-heading">
        <h2>Device Control</h2>
      </div>
      <div class="control-layout">
        <article
          class="nozzle-card panel interactive-panel"
          role="button"
          tabIndex={0}
          onClick={() => props.onOpenHomeAssistant("temperature")}
          onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return;
            event.preventDefault();
            props.onOpenHomeAssistant("temperature");
          }}
        >
          <div class="card-label">Nozzle &amp; Extruder</div>
          <div class="nozzle-content">
            <div class="temperature-reading">
              <strong>{measurement(props.controls.temperatures.nozzle.current)}</strong>
              <span>/{measurement(props.controls.temperatures.nozzle.target, "°C")}</span>
            </div>
            <div class="nozzle-visual" aria-hidden="true">
              <span class="filament-line" />
              <span class="heat-block"><i /></span>
              <span class="nozzle-tip" />
            </div>
          </div>
          <div class="diameter-note">{props.controls.extruder.nozzle_diameter ? `${props.controls.extruder.nozzle_diameter} mm nozzle` : "Nozzle size unavailable"}</div>
        </article>

        <div class="control-stack">
          <article class="light-card panel">
            <button type="button" class="card-open-button" onClick={() => props.onOpenHomeAssistant("light")}>
              <span class="card-label">Light</span>
              <strong>{props.controls.light.on == null ? "Unknown" : props.lightOn ? "On" : "Off"}</strong>
              <span class="card-open-hint">Home lights</span>
            </button>
            <button
              class="switch"
              classList={{ enabled: props.lightOn, pending: props.lightPending }}
              type="button"
              role="switch"
              aria-checked={props.lightOn}
              aria-label="Chamber light"
              disabled={!props.lightControlAvailable || props.lightPending}
              onClick={props.onToggleLight}
            ><span /></button>
          </article>
          <article class="motion-card panel unavailable">
            <div class="card-label">Motion</div>
            <strong>XYZ</strong>
            <span>Controls unavailable</span>
          </article>
        </div>
      </div>

        <div class="telemetry-strip panel">
          <button type="button" onClick={() => props.onOpenHomeAssistant("temperature")}><Icon name="thermometer" size={20} /><span>Bed</span><strong>{measurement(props.controls.temperatures.bed.current, "°")}</strong></button>
          <button type="button" onClick={() => props.onOpenHomeAssistant("fan")}><Icon name="fan" size={20} /><span>Part</span><strong>{measurement(props.controls.fans.cooling_percent, "%")}</strong></button>
          <button type="button" onClick={() => props.onOpenHomeAssistant("fan")}><Icon name="fan" size={20} /><span>Aux</span><strong>{measurement(props.controls.fans.aux_percent, "%")}</strong></button>
          <button type="button" onClick={() => props.onOpenHomeAssistant("fan")}><Icon name="fan" size={20} /><span>Chamber</span><strong>{measurement(props.controls.fans.chamber_percent, "%")}</strong></button>
        </div>
    </section>
  );
}
