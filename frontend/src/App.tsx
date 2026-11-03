import { Match, Show, Switch, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { controlPrint, fetchDashboard, setChamberLight, setPrintSpeed } from "./api";
import { BottomNav, type View } from "./components/BottomNav";
import { CameraCard } from "./components/CameraCard";
import { ConnectionBanner } from "./components/ConnectionBanner";
import { DeviceControls } from "./components/DeviceControls";
import { FilamentSection } from "./components/FilamentSection";
import { JobCard } from "./components/JobCard";
import { PrinterHeader } from "./components/PrinterHeader";
import { SettingsPage } from "./components/SettingsPage";
import { HomeAssistantModal } from "./components/HomeAssistantModal";
import type { PrintCommand } from "./components/PrintControls";
import { EMPTY_DASHBOARD } from "./lib/dashboard";
import type { Dashboard, HomeAssistantGroup } from "./types";

const POLL_INTERVAL_MS = 1_000;
const REQUEST_TIMEOUT_MS = 8_000;
const COMMAND_CONFIRM_TIMEOUT_MS = 8_000;
/** Pausing parks the toolhead first, so the state change lags the command. */
const PRINT_CONFIRM_TIMEOUT_MS = 20_000;

/** Whether the printer's reported state shows the command took effect. */
function printCommandConfirmed(command: PrintCommand, data: Dashboard): boolean {
  const state = data.printer.state;
  switch (command.kind) {
    case "pause": return state === "PAUSE";
    case "resume": return state === "RUNNING";
    case "stop": return state !== "RUNNING" && state !== "PAUSE" && state !== "PREPARE";
    case "speed": return data.controls.print.speed_level === command.level;
  }
}

const PRINT_COMMAND_LABEL: Record<PrintCommand["kind"], string> = {
  pause: "pause",
  resume: "resume",
  stop: "stop",
  speed: "speed change",
};

function App() {
  const [view, setView] = createSignal<View>("devices");
  const [dashboard, setDashboard] = createSignal<Dashboard>();
  const [connectionError, setConnectionError] = createSignal<string>();
  const [commandError, setCommandError] = createSignal<string>();
  const [lightOverride, setLightOverride] = createSignal<boolean>();
  const [lightPending, setLightPending] = createSignal(false);
  const [homeAssistantModal, setHomeAssistantModal] = createSignal<HomeAssistantGroup>();
  const [printPending, setPrintPending] = createSignal<PrintCommand>();
  let printConfirmationTimer: number | undefined;
  let refreshing = false;
  let controller: AbortController | undefined;
  let lightConfirmationTimer: number | undefined;
  let lightCommandController: AbortController | undefined;
  let lightCommandSequence = 0;

  const data = createMemo(() => dashboard() ?? EMPTY_DASHBOARD);
  const isOnline = createMemo(() => Boolean(dashboard() && data().printer.online && !connectionError()));
  const lightOn = createMemo(() => lightOverride() ?? data().controls.light.on ?? false);
  const cameraLive = createMemo(() => isOnline() && data().camera.available && Boolean(data().camera.player_url));
  const alertMessage = createMemo(() => commandError() ?? connectionError());

  const refresh = async () => {
    // The dashboard is only on the devices view, so do not poll behind the
    // settings page.
    if (refreshing || view() !== "devices") return;
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
      const pendingPrint = printPending();
      if (pendingPrint && printCommandConfirmed(pendingPrint, data)) clearPrintPending();
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
      if (printConfirmationTimer != null) window.clearTimeout(printConfirmationTimer);
    });
  });

  const clearPrintPending = () => {
    if (printConfirmationTimer != null) window.clearTimeout(printConfirmationTimer);
    printConfirmationTimer = undefined;
    setPrintPending(undefined);
  };

  const sendPrintCommand = async (command: PrintCommand) => {
    if (!data().capabilities.print_control || printPending()) return;
    setPrintPending(command);
    setCommandError(undefined);
    printConfirmationTimer = window.setTimeout(() => {
      printConfirmationTimer = undefined;
      setPrintPending(undefined);
      setCommandError(`Printer did not confirm the ${PRINT_COMMAND_LABEL[command.kind]}`);
    }, PRINT_CONFIRM_TIMEOUT_MS);

    try {
      if (command.kind === "speed") await setPrintSpeed(command.level);
      else await controlPrint(command.kind);
      void refresh();
    } catch (error) {
      if (printPending() !== command) return;
      clearPrintPending();
      setCommandError(error instanceof Error ? error.message : `Could not send the ${PRINT_COMMAND_LABEL[command.kind]}`);
    }
  };

  const toggleLight = async () => {
    if (!data().capabilities.light_control || lightPending()) return;
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

  const onNavigate = (next: View) => {
    setView(next);
    // Coming back to the devices view should refresh immediately rather than
    // wait a full poll interval.
    if (next === "devices") void refresh();
  };

  return (
    <div class="app-shell">
      <Switch>
        <Match when={view() === "settings"}><SettingsPage /></Match>
        <Match when={true}>
          <main class="dashboard">
            <PrinterHeader printer={data().printer} online={isOnline()} connecting={!dashboard()} />
            <ConnectionBanner message={alertMessage()} onRetry={retry} />

            <div class="dashboard-grid">
              <div class="dashboard-column left">
                <div class="col-camera">
                  <CameraCard
                    camera={data().camera}
                    printerName={data().printer.name}
                    live={cameraLive()}
                    connecting={!dashboard()}
                  />
                </div>
                <div class="col-filament">
                  <FilamentSection filament={data().filament} />
                </div>
              </div>
              <div class="dashboard-column right">
                <div class="col-job">
                  <JobCard job={data().job} />
                </div>
                <div class="col-controls">
                  <DeviceControls
                    controls={data().controls}
                    printState={data().printer.state}
                    printControlAvailable={isOnline() && data().capabilities.print_control}
                    printPending={printPending()}
                    onPrintCommand={(command) => void sendPrintCommand(command)}
                    lightControlAvailable={data().capabilities.light_control}
                    lightOn={lightOn()}
                    lightPending={lightPending()}
                    onToggleLight={() => void toggleLight()}
                    onOpenHomeAssistant={setHomeAssistantModal}
                  />
                </div>
              </div>
            </div>
          </main>
        </Match>
      </Switch>

      <BottomNav view={view()} onNavigate={onNavigate} />
      <Show when={homeAssistantModal()}>
        {(group) => <HomeAssistantModal group={group()} onClose={() => setHomeAssistantModal(undefined)} />}
      </Show>
    </div>
  );
}

export default App;
