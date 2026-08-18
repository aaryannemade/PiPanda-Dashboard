import { For, Match, Show, Switch, createResource, createSignal } from "solid-js";
import {
  ApiError,
  fetchAuthStatus,
  fetchDevices,
  login,
  logout,
  selectDevice,
  submitLoginCode,
  submitTfaCode,
} from "../api";
import type { AuthStatus, LoginResult } from "../types";
import { Icon } from "./Icon";

/** Which login sub-form is shown. Driven by the backend's LoginResult. */
type Step = "credentials" | "code" | "tfa";

function errorText(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "Something went wrong";
}

export function SettingsPage() {
  const [status, { refetch: refetchStatus }] = createResource<AuthStatus>(() => fetchAuthStatus());

  const [step, setStep] = createSignal<Step>("credentials");
  const [account, setAccount] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [region, setRegion] = createSignal<"global" | "china">("global");
  const [codeLogin, setCodeLogin] = createSignal(false);
  const [code, setCode] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string>();
  const [notice, setNotice] = createSignal<string>();

  const applyResult = (result: LoginResult) => {
    switch (result) {
      case "authenticated":
        setStep("credentials");
        setPassword("");
        setCode("");
        setNotice(undefined);
        void refetchStatus();
        void refetchDevices();
        break;
      case "code_required":
        setStep("code");
        setNotice("A verification code has been sent to your account.");
        break;
      case "tfa_required":
        setStep("tfa");
        setNotice("Enter the code from your authenticator app.");
        break;
    }
  };

  const runLogin = async (event: Event) => {
    event.preventDefault();
    if (busy()) return;
    setBusy(true);
    setError(undefined);
    try {
      const result = await login({
        account: account().trim(),
        password: codeLogin() ? undefined : password(),
        region: region(),
        code_login: codeLogin(),
      });
      applyResult(result);
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  const runCode = async (event: Event) => {
    event.preventDefault();
    if (busy()) return;
    setBusy(true);
    setError(undefined);
    try {
      const submit = step() === "tfa" ? submitTfaCode : submitLoginCode;
      applyResult(await submit(code().trim()));
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  const cancelCode = () => {
    setStep("credentials");
    setCode("");
    setNotice(undefined);
    setError(undefined);
  };

  const runLogout = async () => {
    if (busy()) return;
    setBusy(true);
    setError(undefined);
    try {
      await logout();
      setAccount("");
      setPassword("");
      setStep("credentials");
      setNotice(undefined);
      void refetchStatus();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  // Devices are only fetched once authenticated, so this resource keys off the
  // auth status and re-runs when it changes.
  const [devices, { refetch: refetchDevices }] = createResource(
    () => status()?.authenticated ?? false,
    async (authenticated) => (authenticated ? fetchDevices() : []),
  );

  const chooseDevice = async (deviceId: string) => {
    if (busy()) return;
    setBusy(true);
    setError(undefined);
    try {
      await selectDevice(deviceId);
      void refetchStatus();
      void refetchDevices();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <main class="settings">
      <header class="settings-head">
        <Icon name="settings" size={26} />
        <h1>Settings</h1>
      </header>

      <section class="settings-card" aria-label="Bambu Lab account">
        <h2>Bambu Lab account</h2>

        <Show when={error()}>
          <p class="settings-error" role="alert">{error()}</p>
        </Show>
        <Show when={notice()}>
          <p class="settings-notice" role="status">{notice()}</p>
        </Show>

        <Switch>
          {/* Signed in: show the account and offer sign out. */}
          <Match when={status()?.authenticated}>
            <div class="settings-account">
              <div>
                <p class="settings-account-label">Signed in as</p>
                <p class="settings-account-value">{status()?.account}</p>
              </div>
              <span class={`settings-pill ${status()?.connected ? "ok" : "idle"}`}>
                {status()?.connected ? (status()?.online ? "Printer online" : "Connecting…") : "Not connected"}
              </span>
            </div>

            <div class="settings-devices">
              <h3>Printer</h3>
              <Switch>
                <Match when={devices.loading}>
                  <p class="settings-muted">Loading printers…</p>
                </Match>
                <Match when={(devices() ?? []).length === 0}>
                  <p class="settings-muted">No printers are bound to this account.</p>
                </Match>
                <Match when={(devices() ?? []).length > 0}>
                  <ul class="device-list">
                    <For each={devices()}>
                      {(device) => (
                        <li>
                          <button
                            type="button"
                            class={`device-row ${device.selected ? "selected" : ""}`}
                            disabled={busy() || device.selected}
                            onClick={() => void chooseDevice(device.dev_id)}
                          >
                            <span class="device-info">
                              <span class="device-name">{device.name || device.dev_id}</span>
                              <span class="device-meta">{device.model} · {device.online ? "online" : "offline"}</span>
                            </span>
                            <Show when={device.selected} fallback={<span class="device-select">Select</span>}>
                              <span class="device-selected">Selected</span>
                            </Show>
                          </button>
                        </li>
                      )}
                    </For>
                  </ul>
                </Match>
              </Switch>
            </div>

            <button type="button" class="settings-button ghost" disabled={busy()} onClick={() => void runLogout()}>
              Sign out
            </button>
          </Match>

          {/* Awaiting an emailed/texted code or an authenticator code. */}
          <Match when={step() === "code" || step() === "tfa"}>
            <form class="settings-form" onSubmit={runCode}>
              <label>
                <span>{step() === "tfa" ? "Authenticator code" : "Verification code"}</span>
                <input
                  type="text"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  value={code()}
                  onInput={(event) => setCode(event.currentTarget.value)}
                  placeholder="123456"
                  required
                />
              </label>
              <div class="settings-actions">
                <button type="button" class="settings-button ghost" disabled={busy()} onClick={cancelCode}>
                  Back
                </button>
                <button type="submit" class="settings-button" disabled={busy() || code().trim().length === 0}>
                  {busy() ? "Verifying…" : "Verify"}
                </button>
              </div>
            </form>
          </Match>

          {/* Not signed in: credentials form. */}
          <Match when={true}>
            <form class="settings-form" onSubmit={runLogin}>
              <label>
                <span>Account email</span>
                <input
                  type="email"
                  autocomplete="username"
                  value={account()}
                  onInput={(event) => setAccount(event.currentTarget.value)}
                  placeholder="you@example.com"
                  required
                />
              </label>

              <Show when={!codeLogin()}>
                <label>
                  <span>Password</span>
                  <input
                    type="password"
                    autocomplete="current-password"
                    value={password()}
                    onInput={(event) => setPassword(event.currentTarget.value)}
                    required={!codeLogin()}
                  />
                </label>
              </Show>

              <label class="settings-checkbox">
                <input
                  type="checkbox"
                  checked={codeLogin()}
                  onChange={(event) => setCodeLogin(event.currentTarget.checked)}
                />
                <span>Sign in with an emailed code (for accounts without a password)</span>
              </label>

              <label>
                <span>Region</span>
                <select value={region()} onChange={(event) => setRegion(event.currentTarget.value as "global" | "china")}>
                  <option value="global">Global</option>
                  <option value="china">China</option>
                </select>
              </label>

              <button type="submit" class="settings-button" disabled={busy() || account().trim().length === 0}>
                {busy() ? "Signing in…" : "Sign in"}
              </button>
            </form>
          </Match>
        </Switch>
      </section>
    </main>
  );
}
