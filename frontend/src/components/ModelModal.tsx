import { For, Match, Show, Switch, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { Portal } from "solid-js/web";
import { ApiError, fetchMakerworldModel, makerworldCoverUrl } from "../api";
import type { MakerworldModel } from "../types";
import { Icon } from "./Icon";

interface ModelModalProps {
  /** The search hit that was tapped, shown immediately while detail loads. */
  model: MakerworldModel;
  onClose: () => void;
}

function errorText(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "Could not reach MakerWorld";
}

/**
 * MakerWorld descriptions are author-supplied HTML. This page also drives the
 * printer, so that markup is never rendered: the tags are dropped and only the
 * text is shown. `DOMParser` does not execute scripts or load subresources, so
 * parsing here is inert.
 */
function summaryText(html: string): string {
  if (!html) return "";
  const spaced = html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6]|tr)>/gi, "$&\n");
  const parsed = new DOMParser().parseFromString(spaced, "text/html");
  return (parsed.body.textContent ?? "").replace(/\n{3,}/g, "\n\n").trim();
}

/** The cover first, then the maker's gallery, without duplicates or empties. */
function galleryImages(cover: string, pictures: string[]): string[] {
  return [...new Set([cover, ...pictures].filter((url) => url !== ""))];
}

function formatCount(value: number): string {
  return value.toLocaleString();
}

export function ModelModal(props: ModelModalProps) {
  const [detail] = createResource(
    () => props.model.id,
    (id) => fetchMakerworldModel(id),
  );
  const [active, setActive] = createSignal(0);
  let closeButton: HTMLButtonElement | undefined;

  // The cover is known before the detail fetch resolves, so the gallery is
  // usable immediately and only grows.
  const gallery = () => galleryImages(props.model.cover, detail()?.pictures ?? []);

  // Mirrors HomeAssistantModal: lock the page behind the dialog, trap Tab, and
  // give focus back to whatever opened it.
  onMount(() => {
    const previousOverflow = document.body.style.overflow;
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
    const app = document.querySelector<HTMLElement>(".app-shell");
    const wasInert = app?.inert ?? false;
    document.body.style.overflow = "hidden";
    if (app) app.inert = true;
    closeButton?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        props.onClose();
        return;
      }
      if (event.key !== "Tab") return;
      const modal = closeButton?.closest<HTMLElement>(".ha-modal");
      const focusable = modal?.querySelectorAll<HTMLElement>(
        'a[href], button:not(:disabled), input:not(:disabled), [tabindex]:not([tabindex="-1"])',
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    onCleanup(() => {
      document.body.style.overflow = previousOverflow;
      if (app) app.inert = wasInert;
      window.removeEventListener("keydown", onKeyDown);
      previousFocus?.focus();
    });
  });

  return (
    <Portal>
      <div class="ha-modal-backdrop" onClick={(event) => event.target === event.currentTarget && props.onClose()}>
        <section class="ha-modal model-modal" role="dialog" aria-modal="true" aria-labelledby="model-modal-title">
          <button
            ref={closeButton}
            type="button"
            class="model-modal-close"
            aria-label="Close model details"
            onClick={props.onClose}
          >
            <Icon name="close" size={18} />
          </button>

          <div class="model-modal-layout">
            <div class="model-gallery" aria-label="Model images">
              <div class="model-gallery-stage">
                <Show
                  when={gallery()[active()]}
                  fallback={<div class="model-cover-empty"><Icon name="cube" size={48} /></div>}
                >
                  {(src) => (
                    <img
                      classList={{ nsfw: props.model.nsfw }}
                      src={makerworldCoverUrl(src(), 800)}
                      alt={`Image ${active() + 1} of ${props.model.title}`}
                      decoding="async"
                    />
                  )}
                </Show>
              </div>
              <Show when={gallery().length > 1}>
                <div class="model-gallery-thumbs">
                  <For each={gallery()}>
                    {(src, index) => (
                      <button
                        type="button"
                        classList={{ active: index() === active() }}
                        aria-label={`Show image ${index() + 1}`}
                        aria-current={index() === active() ? "true" : undefined}
                        onClick={() => setActive(index())}
                      >
                        <img
                          classList={{ nsfw: props.model.nsfw }}
                          src={makerworldCoverUrl(src, 160)}
                          alt=""
                          loading="lazy"
                          decoding="async"
                        />
                      </button>
                    )}
                  </For>
                </div>
              </Show>
            </div>

            <div class="model-modal-scroll">
              <header class="model-modal-heading">
                <span class="ha-modal-kicker">MakerWorld</span>
                <h2 id="model-modal-title">{props.model.title}</h2>
                <p class="model-modal-creator">{props.model.creator || "Unknown maker"}</p>
              </header>

              <div class="model-modal-stats">
                <span><Icon name="heart" size={15} />{formatCount(props.model.like_count)} likes</span>
                <span><Icon name="download" size={15} />{formatCount(props.model.download_count)} downloads</span>
                <span><Icon name="printer" size={15} />{formatCount(props.model.print_count)} prints</span>
              </div>

              <a
                class="settings-button model-modal-link"
                href={props.model.url}
                target="_blank"
                rel="noreferrer noopener"
              >
                <Icon name="external" size={16} />View on MakerWorld
              </a>
              <p class="model-modal-note">Downloading and slicing happen on MakerWorld; pipanda only browses.</p>

              <Switch>
                <Match when={detail.loading}>
                  <p class="settings-muted" role="status">Loading model details...</p>
                </Match>
                <Match when={detail.error}>
                  <p class="settings-error" role="alert">{errorText(detail.error)}</p>
                </Match>
                <Match when={detail()}>
                  {(loaded) => (
                    <>
                      <Show when={loaded().categories.length > 0}>
                        <p class="model-modal-meta">{loaded().categories.join(" › ")}</p>
                      </Show>

                      <Show
                        when={summaryText(loaded().summary_html)}
                        fallback={<p class="settings-muted">This model has no description.</p>}
                      >
                        {(text) => <p class="model-modal-summary">{text()}</p>}
                      </Show>

                      <Show when={loaded().tags.length > 0}>
                        <ul class="model-tags" aria-label="Tags">
                          <For each={loaded().tags}>{(tag) => <li>{tag}</li>}</For>
                        </ul>
                      </Show>

                      <dl class="model-modal-facts">
                        <Show when={loaded().license}>
                          <div><dt>License</dt><dd>{loaded().license}</dd></div>
                        </Show>
                        <div><dt>Print profiles</dt><dd>{formatCount(loaded().instance_count)}</dd></div>
                        <div><dt>Comments</dt><dd>{formatCount(loaded().comment_count)}</dd></div>
                      </dl>
                    </>
                  )}
                </Match>
              </Switch>
            </div>
          </div>
        </section>
      </div>
    </Portal>
  );
}
