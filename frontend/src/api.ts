import type { Dashboard } from "./types";

const apiBase = (import.meta.env.VITE_API_BASE ?? "").replace(/\/$/, "");

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
    try {
      const payload = (await response.json()) as { error?: { message?: string } };
      message = payload.error?.message ?? message;
    } catch {
      // The status text remains the useful fallback for non-JSON proxy errors.
    }
    throw new Error(message);
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
