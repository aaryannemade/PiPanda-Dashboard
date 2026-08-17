import { Show } from "solid-js";

interface ConnectionBannerProps {
  message: string | undefined;
  onRetry: () => void;
}

export function ConnectionBanner(props: ConnectionBannerProps) {
  return (
    <Show when={props.message}>
      <div class="connection-banner" role="status">
        <span>{props.message}</span>
        <button type="button" onClick={props.onRetry}>Retry</button>
      </div>
    </Show>
  );
}
