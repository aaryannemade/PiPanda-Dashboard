import type { Dashboard } from "../types";

export const EMPTY_DASHBOARD: Dashboard = {
  api_version: 1,
  printer: { id: "", name: "Panda", model: "P1S", online: false, state: null, wifi_signal: null, error_code: null, active_alerts: null },
  camera: { available: false, player_url: null, stream_name: "p1s" },
  job: { name: null, profile: null, thumbnail_url: null, state: null, result: null, progress_percent: null, remaining_minutes: null, layer: null, total_layers: null, actions: { print_again: false, rating: false } },
  controls: {
    temperatures: { nozzle: { current: null, target: null }, bed: { current: null, target: null }, chamber: { current: null, target: null } },
    fans: { cooling_percent: null, aux_percent: null, chamber_percent: null },
    light: { available: false, on: null },
    motion: { available: false },
    extruder: { available: false, nozzle_diameter: null },
  },
  filament: { ams: null, external_spool: null, library: { available: false, roll_count: null } },
  capabilities: { light_control: false, motion_control: false, extruder_control: false, print_again: false, job_rating: false, filament_library: false },
};
