import { Show } from "solid-js";

export type IconName = "camera" | "chevron" | "close" | "cube" | "download" | "droplet" | "external" | "eye" | "fan" | "heart" | "light" | "printer" | "rotate" | "scan" | "search" | "settings" | "star" | "thermometer" | "user";

interface IconProps {
  name: IconName;
  size?: number;
  filled?: boolean;
  class?: string;
}

export function Icon(props: IconProps) {
  const common = {
    width: props.size ?? 24,
    height: props.size ?? 24,
    viewBox: "0 0 24 24",
    fill: props.filled ? "currentColor" : "none",
    stroke: "currentColor",
    "stroke-width": props.filled ? 0 : 1.8,
    "stroke-linecap": "round" as const,
    "stroke-linejoin": "round" as const,
    class: props.class,
    "aria-hidden": true,
  };

  return (
    <svg {...common}>
      <Show when={props.name === "camera"}>
        <path d="M5 7.5h3l1.4-2h5.2l1.4 2h3a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2Z" />
        <circle cx="12" cy="13" r="3.5" />
      </Show>
      <Show when={props.name === "chevron"}><path d="m9 18 6-6-6-6" /></Show>
      <Show when={props.name === "close"}><path d="M6 6l12 12M18 6 6 18" /></Show>
      <Show when={props.name === "cube"}>
        <path d="m12 2.8 8 4.6v9.2l-8 4.6-8-4.6V7.4l8-4.6Z" />
        <path d="m4.4 7.6 7.6 4.3 7.6-4.3M12 12v8.7M8 5l8 4.6M16 5 8 9.6" />
      </Show>
      <Show when={props.name === "download"}>
        <path d="M12 3.5v11m0 0 4-4m-4 4-4-4M4 17.5v1a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1" />
      </Show>
      <Show when={props.name === "droplet"}><path d="M12 2.5s6 6.7 6 11.2a6 6 0 0 1-12 0C6 9.2 12 2.5 12 2.5Z" /></Show>
      <Show when={props.name === "external"}>
        <path d="M14 3.5h6.5V10M20 4l-8.5 8.5" />
        <path d="M19 14.5v4a2 2 0 0 1-2 2H5.5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h4" />
      </Show>
      <Show when={props.name === "eye"}>
        <path d="M2.5 12s3.5-5.5 9.5-5.5 9.5 5.5 9.5 5.5-3.5 5.5-9.5 5.5S2.5 12 2.5 12Z" />
        <circle cx="12" cy="12" r="2.4" />
      </Show>
      <Show when={props.name === "fan"}>
        <circle cx="12" cy="12" r="2" />
        <path d="M12 10c-1.7-2.2-1.1-5.9 1.4-6.6 2.2-.6 3.5 1.7 2.5 3.6-.8 1.5-2.3 2.4-3.9 3ZM14 12c2.2-1.7 5.9-1.1 6.6 1.4.6 2.2-1.7 3.5-3.6 2.5-1.5-.8-2.4-2.3-3-3.9ZM12 14c1.7 2.2 1.1 5.9-1.4 6.6-2.2.6-3.5-1.7-2.5-3.6.8-1.5 2.3-2.4 3.9-3ZM10 12c-2.2 1.7-5.9 1.1-6.6-1.4C2.8 8.4 5.1 7.1 7 8.1c1.5.8 2.4 2.3 3 3.9Z" />
      </Show>
      <Show when={props.name === "heart"}>
        <path d="M12 20.3s-7.7-4.5-7.7-9.8a4.2 4.2 0 0 1 7.7-2.3 4.2 4.2 0 0 1 7.7 2.3c0 5.3-7.7 9.8-7.7 9.8Z" />
      </Show>
      <Show when={props.name === "light"}>
        <path d="M9 18h6M9.7 21h4.6M8.5 15.5A6 6 0 1 1 15.5 15.5c-.8.6-1.1 1.2-1.1 2H9.6c0-.8-.3-1.4-1.1-2Z" />
      </Show>
      <Show when={props.name === "printer"}>
        <path d="M6 8V3h12v5M6 17H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2" />
        <path d="M6 14h12v7H6z" /><path d="M17.5 11h.01" />
      </Show>
      <Show when={props.name === "rotate"}>
        <path d="M20 7v5h-5M4 17v-5h5" />
        <path d="M6.1 8.1A7 7 0 0 1 18.8 7L20 12M4 12l1.2 5a7 7 0 0 0 12.7-1.1" />
      </Show>
      <Show when={props.name === "scan"}>
        <path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3" />
        <path d="M7 12h10" />
      </Show>
      <Show when={props.name === "search"}>
        <circle cx="11" cy="11" r="6.5" /><path d="m16 16 4.5 4.5" />
      </Show>
      <Show when={props.name === "settings"}>
        <path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Z" />
        <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.6v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z" />
      </Show>
      <Show when={props.name === "star"}><path d="m12 2.7 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-2.9-5.6 2.9 1.1-6.2L3 9.3l6.2-.9L12 2.7Z" /></Show>
      <Show when={props.name === "thermometer"}>
        <path d="M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0Z" />
        <circle cx="12" cy="18" r="1.6" />
      </Show>
      <Show when={props.name === "user"}>
        <circle cx="12" cy="8" r="4" /><path d="M4 21a8 8 0 0 1 16 0H4Z" />
      </Show>
    </svg>
  );
}
