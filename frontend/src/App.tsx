import { createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { fetchDashboard, setChamberLight } from "./api";
import { BottomNav } from "./components/BottomNav";
import { CameraCard } from "./components/CameraCard";
import { ConnectionBanner } from "./components/ConnectionBanner";
import { DeviceControls } from "./components/DeviceControls";
import { FilamentSection } from "./components/FilamentSection";
import { JobCard } from "./components/JobCard";
import { PrinterHeader } from "./components/PrinterHeader";
import { EMPTY_DASHBOARD } from "./lib/dashboard";
import type { Dashboard } from "./types";

const POLL_INTERVAL_MS = 1_000;
const REQUEST_TIMEOUT_MS = 8_000;
const COMMAND_CONFIRM_TIMEOUT_MS = 8_000;

function App() {
  const [dashboard, setDashboard] = createSignal<Dashboard>();
  const [connectionError, setConnectionError] = createSignal<string>();
  const [commandError, setCommandError] = createSignal<string>();
  const [lightOverride, setLightOverride] = createSignal<boolean>();
  const [lightPending, setLightPending] = createSignal(false);
  let refreshing = false;
  let controller: AbortController | undefined;
  let lightConfirmationTimer: number | undefined;
  let lightCommandController: AbortController | undefined;
  let lightCommandSequence = 0;

  const view = createMemo(() => dashboard() ?? EMPTY_DASHBOARD);
  const isOnline = createMemo(() => Boolean(dashboard() && view().printer.online && !connectionError()));
  const lightOn = createMemo(() => lightOverride() ?? view().controls.light.on ?? false);
  const cameraLive = createMemo(() => isOnline() && view().camera.available && Boolean(view().camera.player_url));
  const alertMessage = createMemo(() => commandError() ?? connectionError());

  const refresh = async () => {
    if (refreshing) return;
    refreshing = true;
    controller = new AbortController();
    let timedOut = false;
    const requestTimer = window.setTimeout(() => {
      timedOut = true;
      controller?.abort();
    }, REQUEST_TIMEOUT_MS);

    try {
      const data = await fetchDashboard(controller.signal);
      setDashboard(data);
      setConnectionError(undefined);
      if (lightOverride() != null && data.controls.light.on === lightOverride()) {
        lightCommandSequence += 1;
        lightCommandController?.abort();
        lightCommandController = undefined;
        if (lightConfirmationTimer != null) window.clearTimeout(lightConfirmationTimer);
        lightConfirmationTimer = undefined;
        setLightOverride(undefined);
        setLightPending(false);
      }
    } catch (error) {
      if (timedOut) {
        setConnectionError("Dashboard request timed out");
      } else if (!(error instanceof DOMException && error.name === "AbortError")) {
        setConnectionError(error instanceof Error ? error.message : "Backend unavailable");
      }
    } finally {
      window.clearTimeout(requestTimer);
      refreshing = false;
    }
  };

  onMount(() => {
    void refresh();
    const interval = window.setInterval(() => void refresh(), POLL_INTERVAL_MS);
    onCleanup(() => {
      window.clearInterval(interval);
      controller?.abort();
      lightCommandController?.abort();
      if (lightConfirmationTimer != null) window.clearTimeout(lightConfirmationTimer);
    });
  });

  const toggleLight = async () => {
    if (!view().capabilities.light_control || lightPending()) return;
    const next = !lightOn();
    const commandSequence = ++lightCommandSequence;
    lightCommandController?.abort();
    const commandController = new AbortController();
    lightCommandController = commandController;
    setLightOverride(next);
    setLightPending(true);
    setCommandError(undefined);
    lightConfirmationTimer = window.setTimeout(() => {
      if (commandSequence !== lightCommandSequence) return;
      commandController.abort();
      lightCommandController = undefined;
      setLightOverride(undefined);
      setLightPending(false);
      setCommandError("Printer did not confirm the light change");
      lightConfirmationTimer = undefined;
    }, COMMAND_CONFIRM_TIMEOUT_MS);

    try {
      await setChamberLight(next, commandController.signal);
      if (commandSequence !== lightCommandSequence) return;
      void refresh();
    } catch (error) {
      if (commandSequence !== lightCommandSequence || commandController.signal.aborted) return;
      if (lightConfirmationTimer != null) window.clearTimeout(lightConfirmationTimer);
      lightConfirmationTimer = undefined;
      setLightOverride(undefined);
      setLightPending(false);
      setCommandError(error instanceof Error ? error.message : "Could not control chamber light");
    }
  };

  const retry = () => {
    setCommandError(undefined);
    void refresh();
  };

  return (
    <div class="app-shell">
      <main class="dashboard">
        <PrinterHeader printer={view().printer} online={isOnline()} connecting={!dashboard()} />
        <ConnectionBanner message={alertMessage()} onRetry={retry} />

        <section class="hero-grid" aria-label="Printer overview">
          <CameraCard
            camera={view().camera}
            printerName={view().printer.name}
            live={cameraLive()}
            connecting={!dashboard()}
          />
          <JobCard job={view().job} />
        </section>

        <DeviceControls
          controls={view().controls}
          lightControlAvailable={view().capabilities.light_control}
          lightOn={lightOn()}
          lightPending={lightPending()}
          onToggleLight={() => void toggleLight()}
        />
        <FilamentSection filament={view().filament} />
      </main>

      <BottomNav />
    </div>
  );
}

export default App;
