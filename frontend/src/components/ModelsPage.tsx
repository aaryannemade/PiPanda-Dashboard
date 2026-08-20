import { For, Show, createEffect, createSignal, onCleanup } from "solid-js";
import { ApiError, MAKERWORLD_PAGE_SIZE, fetchMakerworldModels, makerworldCoverUrl } from "../api";
import type { MakerworldModel } from "../types";
import { Icon } from "./Icon";
import { ModelModal } from "./ModelModal";

/**
 * Long enough that typing a word does not fire a request per keystroke, short
 * enough that the grid still feels like it is keeping up. Each request holds a
 * backend-side lock, so bursts queue rather than run in parallel.
 */
const SEARCH_DEBOUNCE_MS = 350;

function errorText(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "Could not reach MakerWorld";
}

/** 1200 -> "1.2k". Counts on popular models run to six figures. */
function compactCount(value: number): string {
  if (value < 1000) return String(value);
  if (value < 1_000_000) return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)}k`;
  return `${(value / 1_000_000).toFixed(1)}M`;
}

interface ModelCardProps {
  model: MakerworldModel;
  onOpen: (model: MakerworldModel) => void;
}

function ModelCard(props: ModelCardProps) {
  return (
    <article
      class="model-card"
      classList={{ nsfw: props.model.nsfw }}
      role="button"
      tabIndex={0}
      aria-label={`${props.model.title} by ${props.model.creator || "unknown maker"}`}
      onClick={() => props.onOpen(props.model)}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        props.onOpen(props.model);
      }}
    >
      <div class="model-cover">
        <Show
          when={props.model.cover}
          fallback={<div class="model-cover-empty"><Icon name="cube" size={40} /></div>}
        >
          {(cover) => (
            <img
              src={makerworldCoverUrl(cover(), 400)}
              alt=""
              loading="lazy"
              decoding="async"
            />
          )}
        </Show>
        <Show when={props.model.nsfw}>
          <span class="model-nsfw-badge">Sensitive</span>
        </Show>
      </div>
      <div class="model-card-body">
        <strong class="model-title">{props.model.title}</strong>
        <span class="model-creator">{props.model.creator || "Unknown maker"}</span>
        <div class="model-stats">
          <span><Icon name="heart" size={14} />{compactCount(props.model.like_count)}</span>
          <span><Icon name="download" size={14} />{compactCount(props.model.download_count)}</span>
          <span><Icon name="printer" size={14} />{compactCount(props.model.print_count)}</span>
        </div>
      </div>
    </article>
  );
}

export function ModelsPage() {
  const [query, setQuery] = createSignal("");
  const [keyword, setKeyword] = createSignal("");
  const [models, setModels] = createSignal<MakerworldModel[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string>();
  const [exhausted, setExhausted] = createSignal(false);
  const [selected, setSelected] = createSignal<MakerworldModel>();

  let controller: AbortController | undefined;
  let debounce: number | undefined;
  /// Discriminates a stale reply from the current one, so a slow first page
  /// landing after a newer search cannot overwrite the newer results.
  let sequence = 0;

  /**
   * `offset` is passed in rather than read from `models()` so that this reads
   * no signal at all. It is called from inside an effect, where reading
   * `models()` would make the effect depend on the state it writes and loop.
   */
  const load = async (activeKeyword: string, offset: number) => {
    const append = offset > 0;
    const token = ++sequence;
    controller?.abort();
    const request = new AbortController();
    controller = request;
    setLoading(true);
    setError(undefined);

    try {
      const page = await fetchMakerworldModels(
        { keyword: activeKeyword, offset },
        request.signal,
      );
      if (token !== sequence) return;
      setModels((current) => (append ? [...current, ...page.models] : page.models));
      // `total` is capped at 10000 upstream and so cannot mark the end. A page
      // shorter than the one requested is the only reliable signal.
      setExhausted(page.count < MAKERWORLD_PAGE_SIZE);
    } catch (err) {
      if (token !== sequence) return;
      setError(errorText(err));
    } finally {
      if (token === sequence) setLoading(false);
    }
  };

  // Also performs the initial load: the effect runs once on mount with the
  // empty keyword, which the backend answers with the newest-first feed.
  createEffect(() => {
    const active = keyword();
    void load(active, 0);
  });

  onCleanup(() => {
    sequence += 1;
    controller?.abort();
    if (debounce != null) window.clearTimeout(debounce);
  });

  const onSearchInput = (value: string) => {
    setQuery(value);
    if (debounce != null) window.clearTimeout(debounce);
    debounce = window.setTimeout(() => setKeyword(value.trim()), SEARCH_DEBOUNCE_MS);
  };

  const submitSearch = (event: Event) => {
    event.preventDefault();
    if (debounce != null) window.clearTimeout(debounce);
    setKeyword(query().trim());
  };

  const clearSearch = () => {
    if (debounce != null) window.clearTimeout(debounce);
    setQuery("");
    setKeyword("");
  };

  return (
    <main class="models">
      <header class="models-head">
        <Icon name="cube" size={26} />
        <h1>Models</h1>
      </header>

      <form class="models-search" role="search" onSubmit={submitSearch}>
        <Icon name="search" size={18} class="models-search-icon" />
        <input
          type="search"
          value={query()}
          placeholder="Search MakerWorld"
          aria-label="Search MakerWorld models"
          autocomplete="off"
          onInput={(event) => onSearchInput(event.currentTarget.value)}
        />
        <Show when={query()}>
          <button type="button" class="models-search-clear" onClick={clearSearch}>Clear</button>
        </Show>
      </form>

      <p class="models-caption">
        <Show when={keyword()} fallback="Newest on MakerWorld">
          {(active) => <>Results for &ldquo;{active()}&rdquo;</>}
        </Show>
      </p>

      <Show when={error()}>
        <p class="settings-error" role="alert">{error()}</p>
      </Show>

      <Show when={!loading() && !error() && models().length === 0}>
        <p class="settings-muted">No models matched that search.</p>
      </Show>

      <div class="model-grid">
        <For each={models()}>
          {(model) => <ModelCard model={model} onOpen={setSelected} />}
        </For>
      </div>

      <div class="models-foot">
        <Show when={loading()}>
          <span class="settings-muted" role="status">Loading models...</span>
        </Show>
        <Show when={!loading() && !exhausted() && models().length > 0}>
          <button
            type="button"
            class="settings-button ghost"
            onClick={() => void load(keyword(), models().length)}
          >
            Load more
          </button>
        </Show>
      </div>

      <Show when={selected()}>
        {(model) => <ModelModal model={model()} onClose={() => setSelected(undefined)} />}
      </Show>
    </main>
  );
}
