import { Show, createResource, createSignal } from "solid-js";
import {
  ApiError,
  disconnectHomeAssistant,
  fetchHomeAssistant,
  saveHomeAssistant,
  testHomeAssistant,
} from "../api";
import type { HomeAssistantConfig } from "../types";

function errorText(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "Something went wrong";
}

/**
 * Entity ids are entered one per line. Commas are accepted too, because pasting
 * a list out of Home Assistant's UI tends to produce them.
 */
function parseEntities(text: string): string[] {
  return text
    .split(/[\n,]/)
    .map((entity) => entity.trim())
    .filter((entity) => entity.length > 0);
}

export function HomeAssistantCard() {
  const [config, { refetch }] = createResource<HomeAssistantConfig>(() => fetchHomeAssistant());

  // The form is only seeded once the stored config arrives; until then these
  // stay undefined so a slow request cannot clobber typing already in progress.
  const [url, setUrl] = createSignal<string>();
  const [token, setToken] = createSignal("");
  const [lights, setLights] = createSignal<string>();
  const [temps, setTemps] = createSignal<string>();
  const [fans, setFans] = createSignal<string>();

  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string>();
  const [notice, setNotice] = createSignal<string>();

  const stored = () => config();
  const urlValue = () => url() ?? stored()?.base_url ?? "";
  const lightsValue = () => lights() ?? (stored()?.entities.light ?? []).join("\n");
  const tempsValue = () => temps() ?? (stored()?.entities.temperature ?? []).join("\n");
  const fansValue = () => fans() ?? (stored()?.entities.fan ?? []).join("\n");

  const run = async (action: () => Promise<string>) => {
    if (busy()) return;
    setBusy(true);
    setError(undefined);
    setNotice(undefined);
    try {
      setNotice(await action());
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  const save = (event: Event) => {
    event.preventDefault();
    void run(async () => {
      const trimmedToken = token().trim();
      await saveHomeAssistant({
        base_url: urlValue().trim(),
        // Omitted when left blank so the stored token is kept.
        ...(trimmedToken.length > 0 ? { token: trimmedToken } : {}),
        entities: {
          light: parseEntities(lightsValue()),
          temperature: parseEntities(tempsValue()),
          fan: parseEntities(fansValue()),
        },
      });
      setToken("");
      void refetch();
      return "Connected to Home Assistant.";
    });
  };

  const test = () =>
    void run(async () => {
      await testHomeAssistant();
      return "Home Assistant answered.";
    });

  const disconnect = () =>
    void run(async () => {
      await disconnectHomeAssistant();
      setUrl(undefined);
      setToken("");
      setLights(undefined);
      setTemps(undefined);
      setFans(undefined);
      void refetch();
      return "Home Assistant disconnected.";
    });

  return (
    <section class="settings-card" aria-label="Home Assistant">
      <div class="settings-card-head">
        <h2>Home Assistant</h2>
        <span class={`settings-pill ${stored()?.configured ? "ok" : "idle"}`}>
          {stored()?.configured ? "Connected" : "Not connected"}
        </span>
      </div>

      <p class="settings-muted">
        Create a long-lived access token in Home Assistant under your profile, at the bottom of the
        Security tab. Tap the dashboard's light, temperature, or fan cards to read and control the
        entities configured here.
      </p>

      <Show when={error()}>
        <p class="settings-error" role="alert">{error()}</p>
      </Show>
      <Show when={notice()}>
        <p class="settings-notice" role="status">{notice()}</p>
      </Show>

      <form class="settings-form" onSubmit={save}>
        <label>
          <span>Home Assistant URL</span>
          <input
            type="text"
            inputmode="url"
            placeholder="http://homeassistant.local:8123"
            value={urlValue()}
            onInput={(event) => setUrl(event.currentTarget.value)}
            required
          />
        </label>

        <label>
          <span>Long-lived access token</span>
          <input
            type="password"
            autocomplete="off"
            placeholder={stored()?.configured ? "Stored — leave blank to keep it" : "eyJhbGciOi…"}
            value={token()}
            onInput={(event) => setToken(event.currentTarget.value)}
            required={!stored()?.configured}
          />
        </label>

        <label>
          <span>Light entities</span>
          <textarea
            rows="3"
            spellcheck={false}
            placeholder={"light.kitchen_ceiling\nswitch.desk_lamp"}
            value={lightsValue()}
            onInput={(event) => setLights(event.currentTarget.value)}
          />
        </label>

        <label>
          <span>Temperature entities</span>
          <textarea
            rows="3"
            spellcheck={false}
            placeholder={"sensor.office_temperature"}
            value={tempsValue()}
            onInput={(event) => setTemps(event.currentTarget.value)}
          />
        </label>

        <label>
          <span>Fan entities</span>
          <textarea
            rows="3"
            spellcheck={false}
            placeholder={"fan.enclosure_extractor"}
            value={fansValue()}
            onInput={(event) => setFans(event.currentTarget.value)}
          />
        </label>

        <p class="settings-muted">One entity id per line.</p>

        <div class="settings-actions">
          <Show when={stored()?.configured}>
            <button type="button" class="settings-button ghost" disabled={busy()} onClick={disconnect}>
              Disconnect
            </button>
            <button type="button" class="settings-button ghost" disabled={busy()} onClick={test}>
              Test
            </button>
          </Show>
          <button type="submit" class="settings-button" disabled={busy() || urlValue().trim().length === 0}>
            {busy() ? "Saving…" : stored()?.configured ? "Save changes" : "Connect"}
          </button>
        </div>
      </form>
    </section>
  );
}
