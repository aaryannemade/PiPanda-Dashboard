import { Icon } from "./Icon";

export type View = "devices" | "settings";

interface BottomNavProps {
  view: View;
  onNavigate: (view: View) => void;
}

export function BottomNav(props: BottomNavProps) {
  return (
    <nav class="bottom-nav" aria-label="Primary navigation">
      <button
        type="button"
        class={props.view === "devices" ? "active" : undefined}
        aria-current={props.view === "devices" ? "page" : undefined}
        onClick={() => props.onNavigate("devices")}
      >
        <Icon name="printer" size={28} /><span>Devices</span>
      </button>
      <button
        type="button"
        class={props.view === "settings" ? "active" : undefined}
        aria-current={props.view === "settings" ? "page" : undefined}
        onClick={() => props.onNavigate("settings")}
      >
        <Icon name="settings" size={28} /><span>Settings</span>
      </button>
    </nav>
  );
}
