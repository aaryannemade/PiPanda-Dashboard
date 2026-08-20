export interface Dashboard {
  api_version: number;
  printer: {
    id: string;
    name: string;
    model: string;
    online: boolean;
    state: string | null;
    wifi_signal: string | null;
    error_code: number | null;
    active_alerts: number | null;
  };
  camera: {
    available: boolean;
    player_url: string | null;
    stream_name: string;
  };
  job: {
    name: string | null;
    profile: string | null;
    thumbnail_url: string | null;
    state: string | null;
    result: "success" | "failed" | null;
    progress_percent: number | null;
    remaining_minutes: number | null;
    layer: number | null;
    total_layers: number | null;
    actions: {
      print_again: boolean;
      rating: boolean;
    };
  };
  controls: {
    temperatures: {
      nozzle: Temperature;
      bed: Temperature;
      chamber: Temperature;
    };
    fans: {
      cooling_percent: number | null;
      aux_percent: number | null;
      chamber_percent: number | null;
    };
    light: {
      available: boolean;
      on: boolean | null;
    };
    motion: { available: boolean };
    extruder: {
      available: boolean;
      nozzle_diameter: string | null;
    };
  };
  filament: {
    ams: AmsState | null;
    external_spool: AmsTray | null;
    library: {
      available: boolean;
      roll_count: number | null;
    };
  };
  capabilities: {
    light_control: boolean;
    motion_control: boolean;
    extruder_control: boolean;
    print_again: boolean;
    job_rating: boolean;
    filament_library: boolean;
  };
}

export interface Temperature {
  current: number | null;
  target: number | null;
}

export interface AuthStatus {
  authenticated: boolean;
  account: string | null;
  device_id: string | null;
  device_selected: boolean;
  connected: boolean;
  online: boolean;
  /** A login step is awaiting a follow-up: "code", "tfa" or null. */
  pending: "code" | "tfa" | null;
}

/** Outcome of a login step. `authenticated` means the token is stored. */
export type LoginResult = "authenticated" | "code_required" | "tfa_required";

export interface Device {
  dev_id: string;
  name: string;
  online: boolean;
  model: string;
  selected: boolean;
}

export interface AmsState {
  ams?: AmsUnit[];
  tray_now?: string;
  tray_pre?: string;
  tray_tar?: string;
}

export interface AmsUnit {
  id?: string;
  humidity?: string | number;
  temp?: string | number;
  tray?: AmsTray[];
}

export interface AmsTray {
  id?: string;
  tray_type?: string;
  tray_color?: string;
  tray_sub_brands?: string;
  remain?: number | string;
  tray_info_idx?: string;
}

/** Entity ids grouped by the role the user assigned them. */
export interface HomeAssistantEntities {
  light: string[];
  temperature: string[];
  fan: string[];
}

/**
 * The stored Home Assistant configuration. The access token is deliberately
 * absent: the backend never hands it back, so an edit that does not change it
 * simply omits it.
 */
export interface HomeAssistantConfig {
  configured: boolean;
  base_url: string | null;
  entities: HomeAssistantEntities;
}

export type HomeAssistantGroup = "light" | "temperature" | "fan";

export interface HomeAssistantEntityState {
  entity_id: string;
  group: HomeAssistantGroup;
  name: string;
  state: string;
  available: boolean;
  unit: string | null;
  value: number | null;
  on: boolean | null;
  brightness_percent: number | null;
  supports_brightness: boolean;
  percentage: number | null;
  supports_percentage: boolean;
}

/**
 * One MakerWorld model, already projected down by the backend from the ~45
 * fields the upstream search returns.
 */
export interface MakerworldModel {
  id: number;
  title: string;
  /** CDN cover at full size, or "" when the design has no render. */
  cover: string;
  creator: string;
  like_count: number;
  download_count: number;
  print_count: number;
  collection_count: number;
  nsfw: boolean;
  /** Public page on makerworld.com. */
  url: string;
}

export interface MakerworldPage {
  /** Capped upstream at 10000, so treat it as "at least this many". */
  total: number;
  offset: number;
  count: number;
  models: MakerworldModel[];
}

export interface MakerworldDetail {
  model: MakerworldModel;
  /** Description as HTML. Rendered as text; never assigned to innerHTML. */
  summary_html: string;
  license: string;
  tags: string[];
  categories: string[];
  instance_count: number;
  comment_count: number;
  /** Maker-uploaded gallery images, capped at 12 upstream. The cover is not
   * included; the frontend prepends it so the gallery is usable before this
   * fetch resolves. */
  pictures: string[];
}
