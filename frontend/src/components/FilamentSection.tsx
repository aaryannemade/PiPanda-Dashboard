import { For, Show, createMemo, createSignal } from "solid-js";
import type { JSX } from "solid-js";
import type { AmsTray, Dashboard } from "../types";
import { Icon } from "./Icon";

interface FilamentSectionProps {
  filament: Dashboard["filament"];
}

function normalizeTrayColor(raw?: string): string {
  if (!raw) return "#686b6a";
  const value = raw.replace(/^#/, "").slice(0, 6);
  return /^[0-9a-f]{6}$/i.test(value) ? `#${value}` : "#686b6a";
}

function amsNumber(id: string | undefined, fallback: number): number {
  const value = Number(id);
  return Number.isInteger(value) && value >= 0 ? value : fallback;
}

function amsLetter(id: string | undefined, fallback: number): string {
  return String.fromCharCode(65 + Math.min(25, amsNumber(id, fallback)));
}

function trayIsActive(active: string | undefined, unitId: string | undefined, unitIndex: number, tray: AmsTray, slotIndex: number): boolean {
  if (active == null) return false;
  const unit = amsNumber(unitId, unitIndex);
  const localTray = Number(tray.id ?? slotIndex);
  const local = Number.isInteger(localTray) && localTray >= 0 ? localTray : slotIndex;
  const global = unit * 4 + local;
  return active === String(global) || (local >= 4 && active === String(local));
}

export function FilamentSection(props: FilamentSectionProps) {
  const [source, setSource] = createSignal("ams:0");
  const amsUnits = createMemo(() => props.filament.ams?.ams ?? []);
  const selectedExternal = createMemo(() => source() === "external");
  const selectedAmsIndex = createMemo(() => {
    const parsed = Number(source().split(":")[1]);
    return Number.isInteger(parsed) && amsUnits()[parsed] ? parsed : 0;
  });
  const amsUnit = createMemo(() => amsUnits()[selectedAmsIndex()]);
  const trays = createMemo(() => {
    if (selectedExternal()) return props.filament.external_spool ? [props.filament.external_spool] : [];
    return amsUnit()?.tray ?? [];
  });
  const activeTray = createMemo(() => props.filament.ams?.tray_now);

  return (
    <section class="content-section filament-section">
      <div class="section-heading">
        <h2>Filament</h2>
        <button type="button" disabled>More <Icon name="chevron" size={20} /></button>
      </div>
      <article class="filament-card panel">
        <div class="filament-tabs">
          <For each={amsUnits()}>{(unit, index) => (
            <button
              class="ams-tab"
              classList={{ active: !selectedExternal() && selectedAmsIndex() === index() }}
              type="button"
              aria-label={`Select AMS ${index() + 1}`}
              onClick={() => setSource(`ams:${index()}`)}
            >
              <span class="mini-ams">
                <For each={(unit.tray ?? []).slice(0, 4)}>{(tray) => <i style={{ background: normalizeTrayColor(tray.tray_color) }} />}</For>
              </span>
              AMS{amsUnits().length > 1 ? index() + 1 : ""}
            </button>
          )}</For>
          <button
            class="ams-tab"
            classList={{ active: selectedExternal(), populated: Boolean(props.filament.external_spool) }}
            type="button"
            disabled={!props.filament.external_spool}
            aria-label="Select external spool"
            onClick={() => setSource("external")}
          >
            <span class="external-roll" /> EXT
          </button>
        </div>

        <div class="ams-header">
          <div>
            <strong>{selectedExternal() ? "External Spool" : `AMS-${amsLetter(amsUnit()?.id, selectedAmsIndex())}`}</strong>
            <span>{trays().length ? `${trays().length} ${selectedExternal() ? "spool" : "slots"} connected` : "No filament data"}</span>
          </div>
          <Show when={!selectedExternal() && amsUnit()?.humidity != null}>
            <div class="humidity-pill" title="AMS humidity index"><Icon name="droplet" size={17} filled /> {amsUnit()?.humidity}</div>
          </Show>
        </div>

        <Show when={trays().length} fallback={<div class="empty-filament">Waiting for filament tray data</div>}>
          <div class="spool-grid">
            <For each={trays()}>{(tray, index) => (
              <FilamentSpool
                tray={tray}
                label={selectedExternal() ? "EXT" : `${amsLetter(amsUnit()?.id, selectedAmsIndex())}${index() + 1}`}
                active={selectedExternal()
                  ? activeTray() === "254"
                  : trayIsActive(activeTray(), amsUnit()?.id, selectedAmsIndex(), tray, index())}
              />
            )}</For>
          </div>
        </Show>
      </article>

      <article class="library-card panel">
        <div class="library-heading">
          <span>Filament Library</span>
          <span>{props.filament.library.roll_count ?? 0} rolls <Icon name="chevron" size={19} /></span>
        </div>
        <button type="button" disabled={!props.filament.library.available}>Add Filament</button>
      </article>
    </section>
  );
}

function FilamentSpool(props: { tray: AmsTray; label: string; active: boolean }) {
  const color = () => normalizeTrayColor(props.tray.tray_color);
  const material = () => props.tray.tray_type || "Unknown";
  const remaining = () => {
    const value = Number(props.tray.remain);
    return Number.isFinite(value) && value >= 0 ? `${Math.round(value)}%` : null;
  };

  return (
    <div class="spool-item" classList={{ active: props.active }}>
      <span class="material-name">{material()}</span>
      <div class="spool" style={{ "--spool-color": color() } as JSX.CSSProperties}>
        <span class="spool-flange left" />
        <span class="spool-core">
          <strong>{props.label}</strong>
          <Show when={props.active}><Icon name="eye" size={16} /></Show>
        </span>
        <span class="spool-flange right" />
      </div>
      <span class="remaining">{remaining() ?? props.tray.tray_sub_brands ?? ""}</span>
    </div>
  );
}
