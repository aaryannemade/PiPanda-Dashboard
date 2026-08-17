import { Icon } from "./Icon";

export function BottomNav() {
  return (
    <nav class="bottom-nav" aria-label="Primary navigation">
      <button type="button" disabled><Icon name="cube" size={28} /><span>Models</span></button>
      <button class="active" type="button" aria-current="page"><Icon name="printer" size={28} /><span>Devices</span></button>
      <button type="button" disabled><Icon name="user" size={28} /><span>Me</span></button>
    </nav>
  );
}
