import { For, Match, Show, Switch, createEffect, createMemo, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { Portal } from "solid-js/web";
import { ApiError, controlHomeAssistantEntity, fetchHomeAssistantEntities } from "../api";
import type { HomeAssistantEntityState, HomeAssistantGroup } from "../types";
import { Icon } from "./Icon";

interface HomeAssistantModalProps {
  group: HomeAssistantGroup;
  onClose: () => void;
}

const GROUP_COPY: Record<HomeAssistantGroup, { title: string; description: string }> = {
  light: { title: "Home lights", description: "Switch lights and adjust brightness where supported." },
  temperature: { title: "Home temperatures", description: "Live readings from your configured Home Assistant entities." },
  fan: { title: "Home fans", description: "Switch fans and set speed where supported." },
};

function errorText(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "Could not reach Home Assistant";
}

function displayReading(entity: HomeAssistantEntityState): string {
  if (!entity.available) return entity.state;
  if (entity.value != null) {
    const value = Number.isInteger(entity.value) ? entity.value.toFixed(0) : entity.value.toFixed(1);
    return `${value}${entity.unit ? ` ${entity.unit}` : ""}`;
  }
  return `${entity.state}${entity.unit ? ` ${entity.unit}` : ""}`;
}

interface ControllableEntityProps {
  entity: HomeAssistantEntityState;
  group: "light" | "fan";
  busy: boolean;
  onCommand: (command: { on?: boolean; percentage?: number }) => void;
}

function ControllableEntity(props: ControllableEntityProps) {
  const currentPercentage = () =>
    props.group === "light" ? (props.entity.brightness_percent ?? 100) : (props.entity.percentage ?? 100);
  const [level, setLevel] = createSignal(currentPercentage());
  createEffect(() => setLevel(currentPercentage()));
  const supportsPercentage = () =>
    props.group === "light" ? props.entity.supports_brightness : props.entity.supports_percentage;

  return (
    <article class="ha-entity-row" classList={{ unavailable: !props.entity.available }}>
      <div class="ha-entity-main">
        <div class="ha-entity-icon">
          <Icon name={props.group === "light" ? "light" : "fan"} size={21} />
        </div>
        <div class="ha-entity-copy">
          <strong>{props.entity.name}</strong>
          <span>{props.entity.entity_id}</span>
        </div>
        <button
          class="switch"
          classList={{ enabled: Boolean(props.entity.on), pending: props.busy }}
          type="button"
          role="switch"
          aria-checked={Boolean(props.entity.on)}
          aria-label={props.entity.name}
          disabled={!props.entity.available || props.busy}
          onClick={() => props.onCommand({ on: !props.entity.on })}
        ><span /></button>
      </div>

      <Show when={supportsPercentage()}>
        <label class="ha-level-control">
          <span>{props.group === "light" ? "Brightness" : "Speed"}</span>
          <input
            type="range"
            min="1"
            max="100"
            value={level()}
            disabled={!props.entity.available || props.busy}
            aria-label={`${props.entity.name} ${props.group === "light" ? "brightness" : "speed"}`}
            onInput={(event) => setLevel(Number(event.currentTarget.value))}
            onChange={(event) => props.onCommand({ on: true, percentage: Number(event.currentTarget.value) })}
          />
          <output>{level()}%</output>
        </label>
      </Show>
    </article>
  );
}

export function HomeAssistantModal(props: HomeAssistantModalProps) {
  const [states, { refetch }] = createResource(() => fetchHomeAssistantEntities());
  const [busyEntity, setBusyEntity] = createSignal<string>();
  const [commandError, setCommandError] = createSignal<string>();
  let closeButton: HTMLButtonElement | undefined;

  const entities = createMemo(() => (states() ?? []).filter((entity) => entity.group === props.group));
  const copy = () => GROUP_COPY[props.group];

  onMount(() => {
    const previousOverflow = document.body.style.overflow;
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
    const app = document.querySelector<HTMLElement>(".app-shell");
    const wasInert = app?.inert ?? false;
    document.body.style.overflow = "hidden";
    if (app) app.inert = true;
    closeButton?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        props.onClose();
        return;
      }
      if (event.key !== "Tab") return;
      const modal = closeButton?.closest<HTMLElement>(".ha-modal");
      const focusable = modal?.querySelectorAll<HTMLElement>(
        'button:not(:disabled), input:not(:disabled), [tabindex]:not([tabindex="-1"])',
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    onCleanup(() => {
      document.body.style.overflow = previousOverflow;
      if (app) app.inert = wasInert;
      window.removeEventListener("keydown", onKeyDown);
      previousFocus?.focus();
    });
  });

  const command = async (entity: HomeAssistantEntityState, values: { on?: boolean; percentage?: number }) => {
    if (props.group === "temperature" || busyEntity()) return;
    setBusyEntity(entity.entity_id);
    setCommandError(undefined);
    try {
      await controlHomeAssistantEntity({
        group: props.group,
        entity_id: entity.entity_id,
        ...values,
      });
      await refetch();
    } catch (error) {
      setCommandError(errorText(error));
    } finally {
      setBusyEntity(undefined);
    }
  };

  return (
    <Portal>
      <div class="ha-modal-backdrop" onClick={(event) => event.target === event.currentTarget && props.onClose()}>
        <section class="ha-modal" role="dialog" aria-modal="true" aria-labelledby={`ha-modal-${props.group}`}>
          <header class="ha-modal-head">
            <div>
              <span class="ha-modal-kicker">Home Assistant</span>
              <h2 id={`ha-modal-${props.group}`}>{copy().title}</h2>
              <p>{copy().description}</p>
            </div>
            <button ref={closeButton} type="button" class="ha-modal-close" onClick={props.onClose}>
              Close
            </button>
          </header>

          <Show when={commandError()}>
            <p class="settings-error" role="alert">{commandError()}</p>
          </Show>

          <div class="ha-entity-list">
            <Switch>
              <Match when={states.loading}>
                <div class="ha-modal-state">Loading Home Assistant entities...</div>
              </Match>
              <Match when={states.error}>
                <div class="ha-modal-state error">
                  <p>{errorText(states.error)}</p>
                  <button type="button" class="settings-button ghost" onClick={() => void refetch()}>Retry</button>
                </div>
              </Match>
              <Match when={entities().length === 0}>
                <div class="ha-modal-state">
                  No {props.group === "temperature" ? "temperature" : props.group} entities are configured. Add them in Settings.
                </div>
              </Match>
              <Match when={props.group === "temperature"}>
                <For each={entities()}>
                  {(entity) => (
                    <article class="ha-entity-row temperature" classList={{ unavailable: !entity.available }}>
                      <div class="ha-entity-main">
                        <div class="ha-entity-icon"><Icon name="thermometer" size={21} /></div>
                        <div class="ha-entity-copy">
                          <strong>{entity.name}</strong>
                          <span>{entity.entity_id}</span>
                        </div>
                        <output class="ha-temperature-reading">{displayReading(entity)}</output>
                      </div>
                    </article>
                  )}
                </For>
              </Match>
              <Match when={true}>
                <For each={entities()}>
                  {(entity) => (
                    <ControllableEntity
                      entity={entity}
                      group={props.group as "light" | "fan"}
                      busy={busyEntity() === entity.entity_id}
                      onCommand={(values) => void command(entity, values)}
                    />
                  )}
                </For>
              </Match>
            </Switch>
          </div>

          <footer class="ha-modal-foot">
            <span>State updates when this panel opens and after each command.</span>
            <button type="button" class="settings-button ghost" disabled={states.loading} onClick={() => void refetch()}>
              Refresh
            </button>
          </footer>
        </section>
      </div>
    </Portal>
  );
}
