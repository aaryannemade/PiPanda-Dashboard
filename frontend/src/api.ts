import type { AuthStatus, Dashboard, Device, LoginResult } from "./types";

const apiBase = (import.meta.env.VITE_API_BASE ?? "").replace(/\/$/, "");

/** Carries the backend's machine-readable error code alongside its message. */
export class ApiError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(message: string, code: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

async function apiRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${apiBase}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      ...init?.headers,
    },
  });

  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    let code = "http_error";
    try {
      const payload = (await response.json()) as { error?: { message?: string; code?: string } };
      message = payload.error?.message ?? message;
      code = payload.error?.code ?? code;
    } catch {
      // The status text remains the useful fallback for non-JSON proxy errors.
    }
    throw new ApiError(message, code, response.status);
  }

  return (await response.json()) as T;
}

export function fetchDashboard(signal?: AbortSignal): Promise<Dashboard> {
  return apiRequest<Dashboard>("/api/v1/dashboard", {
    cache: "no-store",
    signal,
  });
}

export function setChamberLight(on: boolean, signal?: AbortSignal): Promise<{ accepted: boolean; mode: string }> {
  return apiRequest("/api/v1/controls/light", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ on }),
    signal,
  });
}

// --- Authentication -------------------------------------------------------

export function fetchAuthStatus(signal?: AbortSignal): Promise<AuthStatus> {
  return apiRequest<AuthStatus>("/api/v1/auth/status", { cache: "no-store", signal });
}

export interface LoginRequest {
  account: string;
  password?: string;
  region?: "global" | "china";
  /** Skip the password and use an emailed/texted code, for password-less accounts. */
  code_login?: boolean;
}

export async function login(body: LoginRequest, signal?: AbortSignal): Promise<LoginResult> {
  const { result } = await apiRequest<{ result: LoginResult }>("/api/v1/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  return result;
}

export async function submitLoginCode(code: string, signal?: AbortSignal): Promise<LoginResult> {
  const { result } = await apiRequest<{ result: LoginResult }>("/api/v1/auth/code", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code }),
    signal,
  });
  return result;
}

export async function submitTfaCode(code: string, signal?: AbortSignal): Promise<LoginResult> {
  const { result } = await apiRequest<{ result: LoginResult }>("/api/v1/auth/tfa", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code }),
    signal,
  });
  return result;
}

export async function fetchDevices(signal?: AbortSignal): Promise<Device[]> {
  const { devices } = await apiRequest<{ devices: Device[] }>("/api/v1/auth/devices", {
    cache: "no-store",
    signal,
  });
  return devices;
}

export function selectDevice(deviceId: string, signal?: AbortSignal): Promise<{ selected: boolean }> {
  return apiRequest("/api/v1/auth/select", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId }),
    signal,
  });
}

export function logout(signal?: AbortSignal): Promise<{ logged_out: boolean }> {
  return apiRequest("/api/v1/auth/logout", { method: "POST", signal });
}
