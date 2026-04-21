defmodule LynxWeb.CoreComponents do
  @moduledoc """
  Shared UI components for the Lynx admin interface.

  All colors use semantic tokens from @theme in app.css.
  Accent: accent, accent-hover  |  Surfaces: surface, modal, nav, input, inset, code, page
  Text: foreground, secondary, muted, clickable  |  Borders: border, border-input
  Status: badge-success-*, badge-danger-*, etc.  |  Selection: select-bg, select-text
  """

  use Phoenix.Component
  use Gettext, backend: LynxWeb.Gettext

  alias Phoenix.LiveView.JS

  # -- Flash --

  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      class={[
        "fixed top-4 right-4 z-[70] rounded-lg px-4 py-3 shadow-lg text-sm max-w-md",
        @kind == :info && "bg-flash-success-bg text-flash-success-text border border-flash-success-border",
        @kind == :error && "bg-flash-error-bg text-flash-error-text border border-flash-error-border"
      ]}
      id={"flash-#{@kind}"}
      phx-hook=".AutoDismiss"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide()}
    >
      <div class="flex items-center gap-2">
        <span :if={@kind == :info}>✓</span>
        <span :if={@kind == :error}>✕</span>
        <span>{msg}</span>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismiss">
      export default {
        mounted() {
          this.timer = setTimeout(() => {
            this.el.style.transition = "opacity 500ms"
            this.el.style.opacity = "0"
            setTimeout(() => { this.el.remove() }, 500)
          }, 5000)
        },
        destroyed() {
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:info} />
    <.flash flash={@flash} kind={:error} />
    """
  end

  # -- Modal --

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_close, :string, default: nil, doc: "phx-click event to fire when closing"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      class="relative z-50 hidden"
    >
      <div class="fixed inset-0 bg-black/50 transition-opacity" aria-hidden="true" phx-click={@on_close} />
      <div class="fixed inset-0 overflow-y-auto pointer-events-none">
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="w-full max-w-2xl rounded-xl bg-modal p-6 shadow-xl ring-1 ring-border relative pointer-events-auto">
            <button :if={@on_close} phx-click={@on_close} class="absolute top-4 right-4 text-muted hover:text-secondary text-xl cursor-pointer">&times;</button>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  def show_modal(id) do
    JS.show(to: "##{id}")
    |> JS.focus_first(to: "##{id}")
  end

  def hide_modal(id) do
    JS.hide(to: "##{id}")
  end

  # -- Confirm Dialog --

  attr :id, :string, default: "confirm-dialog"
  attr :title, :string, default: "Are you sure?"
  attr :message, :string, required: true
  attr :confirm_event, :string, required: true
  attr :confirm_value, :map, default: %{}

  def confirm_dialog(assigns) do
    ~H"""
    <div id={@id} class="relative z-[60]">
      <div class="fixed inset-0 bg-black/50 transition-opacity" phx-click="cancel_confirm" />
      <div class="fixed inset-0 overflow-y-auto pointer-events-none">
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="w-full max-w-sm rounded-xl bg-modal p-6 shadow-xl pointer-events-auto">
            <h3 class="text-lg font-semibold text-foreground mb-2">{@title}</h3>
            <p class="text-sm text-secondary mb-6">{@message}</p>
            <div class="flex justify-end gap-3">
              <.button phx-click="cancel_confirm" variant="secondary" size="sm">Cancel</.button>
              <.button phx-click={@confirm_event} phx-value-uuid={@confirm_value[:uuid]} variant="danger" size="sm">Confirm</.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Table --

  attr :id, :string, default: nil
  attr :rows, :list, required: true
  attr :empty_message, :string, default: "No records found."
  attr :row_click, :any, default: nil, doc: "fn(row) -> JS command for row click"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="border-b border-border text-left text-secondary font-medium">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            class={["border-b border-border hover:bg-surface-secondary", @row_click && "cursor-pointer"]}
          >
            <td
              :for={col <- @col}
              class="px-4 py-3"
              phx-click={@row_click && @row_click.(row)}
            >
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-4 py-3">
              <div class="flex gap-2">
                {render_slot(@action, row)}
              </div>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} class="px-4 py-8 text-center text-muted">
              {@empty_message}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # -- Pagination --

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true

  def pagination(assigns) do
    ~H"""
    <div :if={@total_pages > 1} class="flex items-center justify-between mt-4 px-4">
      <button
        phx-click="prev_page"
        disabled={@page <= 1}
        class="px-3 py-1.5 text-sm rounded border border-border-input text-secondary hover:bg-surface-secondary disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>
      <span class="text-sm text-secondary">{@page} / {@total_pages}</span>
      <button
        phx-click="next_page"
        disabled={@page >= @total_pages}
        class="px-3 py-1.5 text-sm rounded border border-border-input text-secondary hover:bg-surface-secondary disabled:opacity-40 disabled:cursor-not-allowed"
      >
        Next →
      </button>
    </div>
    """
  end

  # -- Badge --

  attr :color, :string, default: "gray"
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
      badge_color(@color),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_color("green"), do: "bg-badge-success-bg text-badge-success-text"
  defp badge_color("red"), do: "bg-badge-danger-bg text-badge-danger-text"
  defp badge_color("yellow"), do: "bg-badge-warning-bg text-badge-warning-text"
  defp badge_color("blue"), do: "bg-badge-info-bg text-badge-info-text"
  defp badge_color("purple"), do: "bg-badge-purple-bg text-badge-purple-text"
  defp badge_color(_), do: "bg-badge-neutral-bg text-badge-neutral-text"

  # -- Button --

  attr :type, :string, default: "button"
  attr :variant, :string, default: "primary"
  attr :size, :string, default: "md"
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(disabled form name value autofocus)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center rounded-lg font-medium transition-colors cursor-pointer focus:outline-none focus:ring-2 focus:ring-offset-2",
        button_size(@size),
        button_variant(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_size("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size("md"), do: "px-4 py-2 text-sm"
  defp button_size("lg"), do: "px-6 py-3 text-base"

  defp button_variant("primary"),
    do: "bg-accent text-on-primary hover:bg-accent-hover focus:ring-accent"

  defp button_variant("secondary"),
    do:
      "bg-surface text-secondary border border-border-input hover:bg-surface-secondary focus:ring-ring"

  defp button_variant("danger"),
    do: "bg-danger text-white hover:bg-danger-hover focus:ring-danger"

  defp button_variant("ghost"),
    do: "text-secondary hover:text-foreground hover:bg-surface-secondary focus:ring-ring"

  # -- Simple Form --

  attr :for, :any, required: true
  attr :as, :any, default: nil

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart)

  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-4">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="flex items-center gap-3 pt-2">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  # -- Input --

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, doc: "a form field struct"
  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkboxes"
  attr :prompt, :string, default: nil
  attr :options, :list, doc: "select options"
  attr :multiple, :boolean, default: false
  attr :hint, :string, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                                    multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <label class="flex items-center gap-3 cursor-pointer">
      <div class="relative">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} class="peer sr-only" {@rest} />
        <div class="w-10 h-5 bg-inset peer-checked:bg-accent rounded-full transition-colors"></div>
        <div class="absolute top-0.5 left-0.5 w-4 h-4 bg-surface rounded-full shadow peer-checked:translate-x-5 transition-transform"></div>
      </div>
      <span :if={@label} class="text-sm font-medium text-secondary">{@label}</span>
    </label>
    <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign(assigns, :display_label, select_display_label(assigns))

    ~H"""
    <div>
      <label :if={@label} class="block text-sm font-medium text-secondary mb-1">{@label}</label>
      <div
        id={@id || @name}
        phx-hook=".CustomSelect"
        phx-update="ignore"
        data-name={@name}
        data-multiple={to_string(@multiple)}
        class="relative"
      >
        <div data-inputs>
          <%= if @multiple do %>
            <input :for={v <- Enum.reject(List.wrap(@value), &(&1 in [nil, ""]))} type="hidden" name={@name <> "[]"} value={v} />
          <% else %>
            <input type="hidden" name={@name} value={@value} />
          <% end %>
        </div>
        <button
          type="button"
          data-trigger
          class="w-full rounded-lg border border-border-input bg-input text-foreground px-3 py-2 text-sm text-left flex items-center justify-between hover:border-muted focus:border-accent-focus-border focus:ring-2 focus:ring-accent-focus-ring cursor-pointer"
        >
          <span data-label class="truncate">{@display_label}</span>
          <svg class="w-4 h-4 text-muted shrink-0 ml-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        <div data-dropdown class="hidden fixed z-50 rounded-lg border border-border bg-surface shadow-lg max-h-60 overflow-auto">
          <div :if={@prompt} data-value="" data-label={@prompt} class="px-3 py-2 text-sm text-muted hover:bg-surface-secondary cursor-pointer">{@prompt}</div>
          <div
            :for={{label, value} <- @options}
            data-value={value}
            data-label={label}
            data-selected={to_string(select_option_active?(value, assigns))}
            class={["px-3 py-2 text-sm hover:bg-select-bg cursor-pointer flex items-center gap-2", select_option_active?(value, assigns) && "bg-select-bg text-select-text"]}
          >
            <span :if={@multiple} data-check class="text-accent w-4">{if select_option_active?(value, assigns), do: "✓", else: ""}</span>
            {label}
          </div>
        </div>
      </div>
      <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CustomSelect">
      export default {
        mounted() {
          this.isOpen = false
          this.multiple = this.el.dataset.multiple === "true"
          this.name = this.el.dataset.name

          this.trigger = this.el.querySelector("[data-trigger]")
          this.dropdown = this.el.querySelector("[data-dropdown]")
          this.inputs = this.el.querySelector("[data-inputs]")
          this.labelEl = this.trigger.querySelector("[data-label]")

          this.trigger.addEventListener("click", e => {
            e.preventDefault()
            this.isOpen ? this.close() : this.open()
          })

          this.dropdown.addEventListener("click", e => {
            let opt = e.target.closest("[data-value]")
            if (!opt) return

            if (this.multiple) {
              let wasSelected = opt.dataset.selected === "true"
              opt.dataset.selected = wasSelected ? "false" : "true"
              opt.classList.toggle("bg-select-bg", !wasSelected)
              opt.classList.toggle("text-select-text", !wasSelected)
              let check = opt.querySelector("[data-check]")
              if (check) check.textContent = !wasSelected ? "\u2713" : ""
              this.syncMultiple()
            } else {
              this.dropdown.querySelectorAll("[data-value]").forEach(o => {
                o.classList.remove("bg-select-bg", "text-select-text")
              })
              opt.classList.add("bg-select-bg", "text-select-text")
              this.labelEl.textContent = opt.dataset.label
              this.inputs.innerHTML = `<input type="hidden" name="${this.name}" value="${this.esc(opt.dataset.value)}" />`
              this.close()
              this.notify()
            }
          })

          this._close = e => { if (!this.el.contains(e.target)) this.close() }
          this._esc = e => { if (e.key === "Escape") this.close() }
          document.addEventListener("click", this._close)
          document.addEventListener("keydown", this._esc)
        },

        destroyed() {
          document.removeEventListener("click", this._close)
          document.removeEventListener("keydown", this._esc)
        },

        open() {
          this.isOpen = true
          // Reveal first so the dropdown has measurable dimensions
          // (display:none returns scrollHeight 0, defeating the flip-above
          // logic). Use visibility:hidden during the measurement to avoid a
          // flash at the wrong position before position() runs.
          this.dropdown.style.visibility = "hidden"
          this.dropdown.classList.remove("hidden")
          this.position()
          this.dropdown.style.visibility = ""
          this._reposition = () => this.position()
          window.addEventListener("scroll", this._reposition, true)
          window.addEventListener("resize", this._reposition)
        },

        close() {
          this.isOpen = false
          this.dropdown.classList.add("hidden")
          if (this._reposition) {
            window.removeEventListener("scroll", this._reposition, true)
            window.removeEventListener("resize", this._reposition)
            this._reposition = null
          }
        },

        position() {
          // Anchor the dropdown to the trigger's viewport rect. Using `fixed`
          // (set in the markup class) lets it escape ancestor `overflow` boxes
          // — without this, dropdowns inside <.table> get clipped and scroll
          // the whole table when opened.
          let r = this.trigger.getBoundingClientRect()
          let dropdownHeight = Math.min(this.dropdown.scrollHeight, 240) // matches max-h-60
          let spaceBelow = window.innerHeight - r.bottom
          let placeAbove = spaceBelow < dropdownHeight + 8 && r.top > dropdownHeight + 8

          this.dropdown.style.left = `${r.left}px`
          this.dropdown.style.width = `${r.width}px`
          if (placeAbove) {
            this.dropdown.style.top = `${r.top - dropdownHeight - 4}px`
          } else {
            this.dropdown.style.top = `${r.bottom + 4}px`
          }
        },

        syncMultiple() {
          let selected = this.dropdown.querySelectorAll('[data-selected="true"]')
          let n = this.name + "[]"
          let html = ""
          let labels = []
          selected.forEach(s => {
            html += `<input type="hidden" name="${n}" value="${this.esc(s.dataset.value)}" />`
            labels.push(s.dataset.label)
          })
          this.inputs.innerHTML = html
          this.labelEl.textContent = labels.length ? labels.join(", ") : "Select..."
        },

        notify() {
          let input = this.inputs.querySelector("input")
          if (input) input.dispatchEvent(new Event("input", { bubbles: true }))
        },

        esc(s) {
          let d = document.createElement("div")
          d.textContent = s
          return d.innerHTML
        }
      }
    </script>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-secondary mb-1">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class="w-full rounded-lg border border-border-input bg-input text-foreground px-3 py-2 text-sm focus:border-accent-focus-border focus:ring-1 focus:ring-accent"
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-secondary mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="w-full rounded-lg border border-border-input bg-input text-foreground px-3 py-2 text-sm focus:border-accent-focus-border focus:ring-1 focus:ring-accent"
        {@rest}
      />
      <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # -- Date input (Flatpickr-backed) --
  #
  # Wraps a hidden text input with a Flatpickr instance so the calendar
  # popup matches our theme (the OS-native `<input type="date">` popup
  # isn't stylable). The hidden input is named like a normal form field —
  # parent `phx-change` handlers receive the value as `YYYY-MM-DD` strings
  # exactly like the native type="date" did, so swap-out is drop-in.

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "YYYY-MM-DD"
  attr :hint, :string, default: nil

  def date_input(assigns) do
    ~H"""
    <div>
      <label :if={@label} class="block text-sm font-medium text-secondary mb-1">{@label}</label>
      <div id={@id} phx-hook=".DateInput" phx-update="ignore" data-initial={@value || ""}>
        <input
          type="text"
          name={@name}
          data-input
          value={@value}
          placeholder={@placeholder}
          autocomplete="off"
          class="w-full rounded-lg border border-border-input bg-input text-foreground px-3 py-2 text-sm focus:border-accent-focus-border focus:ring-1 focus:ring-accent"
        />
      </div>
      <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DateInput">
      export default {
        mounted() {
          this.input = this.el.querySelector("[data-input]")
          // Surface every Flatpickr selection through the hidden input's
          // bubbling `input` event so the enclosing `<form phx-change>`
          // fires exactly like a native date picker would.
          this.fp = window.flatpickr(this.input, {
            dateFormat: "Y-m-d",
            allowInput: true,
            defaultDate: this.el.dataset.initial || null,
            onChange: () => {
              this.input.dispatchEvent(new Event("input", { bubbles: true }))
            },
            onClose: () => {
              this.input.dispatchEvent(new Event("input", { bubbles: true }))
            }
          })
        },
        destroyed() {
          if (this.fp) this.fp.destroy()
        }
      }
    </script>
    """
  end

  # -- Combobox (autocomplete) --
  #
  # Server-side search dropdown for picking from large lists. Replaces the
  # eager-loaded `<.input type="select">` for users / teams / projects /
  # workspaces. Lives inside a `<form phx-change="...">` — the search input
  # debounces keystrokes through that change handler, and option clicks
  # mutate hidden inputs (via the colocated hook) and re-fire the change so
  # the parent can recompute options and selection.
  #
  # `phx-update="ignore"` on the hidden-input + trigger regions: once mounted,
  # the hook owns chip/label state. The dropdown's results region re-renders
  # normally so search results stay in sync with the `:options` assign.

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "Type to search…"
  attr :prompt, :string, default: "Select…"
  attr :options, :list, default: [], doc: "current results: [{label, value}, ...]"

  attr :selected, :any,
    default: nil,
    doc: "single: {label, value} or nil; multi: [{label, value}, ...]"

  attr :multiple, :boolean, default: false
  attr :hint, :string, default: nil
  attr :empty_label, :string, default: "No matches"
  attr :required, :boolean, default: false

  def combobox(assigns) do
    assigns =
      assigns
      |> assign(:selected_list, normalize_selected(assigns))

    ~H"""
    <div>
      <label :if={@label} class="block text-sm font-medium text-secondary mb-1">{@label}</label>
      <div
        id={@id}
        phx-hook=".Combobox"
        data-multiple={to_string(@multiple)}
        data-name={@name}
        data-prompt={@prompt}
        data-required={to_string(@required)}
        class="relative"
      >
        <div data-inputs phx-update="ignore" id={"#{@id}-inputs"}>
          <%= if @multiple do %>
            <input :for={{_label, value} <- @selected_list} type="hidden" name={@name <> "[]"} value={value} data-selected-value={value} />
          <% else %>
            <input type="hidden" name={@name} value={selected_single_value(@selected_list)} />
          <% end %>
        </div>

        <div
          data-trigger
          phx-update="ignore"
          id={"#{@id}-trigger"}
          tabindex="0"
          class="w-full rounded-lg border border-border-input bg-input text-foreground px-3 py-2 text-sm flex items-center justify-between hover:border-muted focus:border-accent-focus-border focus:ring-2 focus:ring-accent-focus-ring cursor-pointer min-h-[38px]"
          data-initial={Jason.encode!(initial_payload(@selected_list, @multiple, @prompt))}
        >
          <div data-trigger-content class="flex flex-wrap gap-1 items-center min-w-0 flex-1"></div>
          <svg class="w-4 h-4 text-muted shrink-0 ml-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
        </div>

        <div data-dropdown class="hidden fixed z-50 rounded-lg border border-border bg-surface shadow-lg w-full">
          <div class="p-2 border-b border-border" phx-update="ignore" id={"#{@id}-search-wrap"}>
            <input
              data-search
              type="text"
              name={"_q_" <> @name}
              value=""
              placeholder={@placeholder}
              phx-debounce="200"
              autocomplete="off"
              class="w-full rounded-md border border-border-input bg-input text-foreground px-3 py-1.5 text-sm focus:border-accent-focus-border focus:ring-1 focus:ring-accent"
            />
          </div>
          <div data-results class="max-h-60 overflow-auto">
            <div :if={@options == []} class="px-3 py-2 text-sm text-muted">{@empty_label}</div>
            <div
              :for={{label, value} <- @options}
              data-option
              data-value={value}
              data-label={label}
              class="px-3 py-2 text-sm hover:bg-select-bg cursor-pointer flex items-center gap-2"
            >
              <span :if={@multiple} data-check class="text-accent w-4"></span>
              <span class="truncate">{label}</span>
            </div>
          </div>
        </div>
      </div>
      <p :if={@hint} class="mt-1 text-xs text-muted">{@hint}</p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Combobox">
      export default {
        mounted() {
          this.isOpen = false
          this.multiple = this.el.dataset.multiple === "true"
          this.name = this.el.dataset.name
          this.prompt = this.el.dataset.prompt

          this.inputs = this.el.querySelector("[data-inputs]")
          this.trigger = this.el.querySelector("[data-trigger]")
          this.triggerContent = this.trigger.querySelector("[data-trigger-content]")
          this.dropdown = this.el.querySelector("[data-dropdown]")
          this.search = this.dropdown.querySelector("[data-search]")
          this.results = this.dropdown.querySelector("[data-results]")

          // Selected state: array of {label, value} for both modes (single = max 1)
          let initial = JSON.parse(this.trigger.dataset.initial || "[]")
          this.selected = initial
          this.renderTrigger()

          this.trigger.addEventListener("click", (e) => {
            if (e.target.closest("[data-chip-remove]")) return
            e.preventDefault()
            this.isOpen ? this.close() : this.open()
          })

          this.trigger.addEventListener("keydown", (e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault()
              this.isOpen ? this.close() : this.open()
            } else if (e.key === "Escape") {
              this.close()
            }
          })

          this.trigger.addEventListener("click", (e) => {
            let removeBtn = e.target.closest("[data-chip-remove]")
            if (!removeBtn) return
            e.preventDefault()
            e.stopPropagation()
            this.removeSelected(removeBtn.dataset.value)
          })

          this.results.addEventListener("click", (e) => {
            let opt = e.target.closest("[data-option]")
            if (!opt) return
            e.preventDefault()
            this.toggleOption(opt.dataset.value, opt.dataset.label)
          })

          this.search.addEventListener("keydown", (e) => {
            if (e.key === "Escape") {
              e.preventDefault()
              this.close()
              this.trigger.focus()
            }
          })

          this._close = (e) => { if (!this.el.contains(e.target)) this.close() }
          document.addEventListener("click", this._close)

          // Mark already-selected options on first mount — the server-rendered
          // option list is in the DOM (just hidden) and needs the highlight +
          // checkmark applied before the user opens the dropdown.
          this.markSelectedOptions()
        },

        updated() {
          // Server re-renders reset our class list — re-apply open state and
          // re-sync option highlighting with the current selection.
          if (this.isOpen) {
            this.dropdown.classList.remove("hidden")
            this.position()
          }
          this.markSelectedOptions()
        },

        destroyed() {
          document.removeEventListener("click", this._close)
          if (this._reposition) {
            window.removeEventListener("scroll", this._reposition, true)
            window.removeEventListener("resize", this._reposition)
          }
        },

        toggleOption(value, label) {
          if (this.multiple) {
            let existing = this.selected.find(s => s.value === value)
            if (existing) {
              this.selected = this.selected.filter(s => s.value !== value)
            } else {
              this.selected = [...this.selected, { label, value }]
            }
          } else {
            this.selected = [{ label, value }]
          }
          this.syncInputs()
          this.renderTrigger()
          this.markSelectedOptions()
          this.notify()
          if (!this.multiple) this.close()
        },

        removeSelected(value) {
          this.selected = this.selected.filter(s => s.value !== value)
          this.syncInputs()
          this.renderTrigger()
          this.markSelectedOptions()
          this.notify()
        },

        syncInputs() {
          let html = ""
          if (this.multiple) {
            this.selected.forEach(s => {
              html += `<input type="hidden" name="${this.name}[]" value="${this.esc(s.value)}" data-selected-value="${this.esc(s.value)}" />`
            })
          } else {
            let v = this.selected[0]?.value || ""
            html = `<input type="hidden" name="${this.name}" value="${this.esc(v)}" />`
          }
          this.inputs.innerHTML = html
        },

        renderTrigger() {
          if (this.selected.length === 0) {
            this.triggerContent.innerHTML = `<span class="text-muted">${this.esc(this.prompt)}</span>`
            return
          }
          if (this.multiple) {
            this.triggerContent.innerHTML = this.selected.map(s => `
              <span class="inline-flex items-center gap-1 rounded-md bg-inset text-foreground text-xs px-2 py-0.5">
                <span class="truncate max-w-[180px]">${this.esc(s.label)}</span>
                <button type="button" data-chip-remove data-value="${this.esc(s.value)}" class="text-muted hover:text-foreground leading-none">&times;</button>
              </span>
            `).join("")
          } else {
            this.triggerContent.innerHTML = `<span class="truncate">${this.esc(this.selected[0].label)}</span>`
          }
        },

        markSelectedOptions() {
          let selectedValues = new Set(this.selected.map(s => s.value))
          this.results.querySelectorAll("[data-option]").forEach(opt => {
            let isSel = selectedValues.has(opt.dataset.value)
            opt.classList.toggle("bg-select-bg", isSel)
            opt.classList.toggle("text-select-text", isSel)
            let check = opt.querySelector("[data-check]")
            if (check) check.textContent = isSel ? "\u2713" : ""
          })
        },

        notify() {
          // Bubble an input event so the enclosing <form phx-change> fires.
          let synthetic = this.inputs.querySelector("input") || this.inputs
          synthetic.dispatchEvent(new Event("input", { bubbles: true }))
        },

        open() {
          this.isOpen = true
          this.dropdown.style.visibility = "hidden"
          this.dropdown.classList.remove("hidden")
          this.position()
          this.dropdown.style.visibility = ""
          this.search.value = ""
          this.search.focus()
          this._reposition = () => this.position()
          window.addEventListener("scroll", this._reposition, true)
          window.addEventListener("resize", this._reposition)
        },

        close() {
          this.isOpen = false
          this.dropdown.classList.add("hidden")
          if (this._reposition) {
            window.removeEventListener("scroll", this._reposition, true)
            window.removeEventListener("resize", this._reposition)
            this._reposition = null
          }
        },

        position() {
          let r = this.trigger.getBoundingClientRect()
          let dropdownHeight = Math.min(this.dropdown.scrollHeight, 320)
          let spaceBelow = window.innerHeight - r.bottom
          let placeAbove = spaceBelow < dropdownHeight + 8 && r.top > dropdownHeight + 8

          this.dropdown.style.left = `${r.left}px`
          this.dropdown.style.width = `${r.width}px`
          if (placeAbove) {
            this.dropdown.style.top = `${r.top - dropdownHeight - 4}px`
          } else {
            this.dropdown.style.top = `${r.bottom + 4}px`
          }
        },

        esc(s) {
          let d = document.createElement("div")
          d.textContent = s == null ? "" : String(s)
          return d.innerHTML
        }
      }
    </script>
    """
  end

  defp normalize_selected(%{multiple: true, selected: nil}), do: []
  defp normalize_selected(%{multiple: true, selected: list}) when is_list(list), do: list
  defp normalize_selected(%{multiple: false, selected: nil}), do: []
  defp normalize_selected(%{multiple: false, selected: {_l, _v} = pair}), do: [pair]
  defp normalize_selected(_), do: []

  defp selected_single_value([]), do: ""
  defp selected_single_value([{_label, value} | _]), do: value

  defp initial_payload(selected_list, _multiple, _prompt) do
    Enum.map(selected_list, fn {label, value} -> %{label: label, value: value} end)
  end

  # -- Error --

  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-badge-danger-text">{render_slot(@inner_block)}</p>
    """
  end

  # -- Page Header --

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  def page_header(assigns) do
    ~H"""
    <div class="bg-gradient-to-r from-header-from to-header-to rounded-2xl px-8 py-10 mb-8">
      <h1 class="text-3xl font-bold text-on-primary">{@title}</h1>
      <p :if={@subtitle} class="mt-2 text-header-subtitle">{@subtitle}</p>
    </div>
    """
  end

  # -- Card --

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["bg-surface rounded-xl shadow-sm border border-border p-6", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # -- Nav --

  attr :current_user, :any, required: true
  attr :active, :string, default: ""

  def nav(assigns) do
    ~H"""
    <nav class="bg-nav border-b border-border px-6 py-3 mb-6 sticky top-0 z-40">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-8">
          <a href="/" class="flex items-center gap-2">
            <.logo />
          </a>
          <div :if={@current_user} class="flex items-center gap-1">
            <.nav_link href="/admin/workspaces" active={@active == "workspaces"}>Workspaces</.nav_link>
            <.nav_link href="/admin/snapshots" active={@active == "snapshots"}>Snapshots</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/teams" active={@active == "teams"}>Teams</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/users" active={@active == "users"}>Users</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/settings" active={@active == "settings"}>Settings</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/audit" active={@active == "audit"}>Audit Log</.nav_link>
          </div>
        </div>
        <div :if={@current_user} class="flex items-center gap-4">
          <a href="/admin/profile" class="text-sm text-secondary hover:text-foreground">{@current_user.name}</a>
          <a href="/logout" class="text-sm text-muted hover:text-secondary">Logout</a>
          <.dark_mode_toggle />
        </div>
      </div>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        @active && "bg-select-bg text-select-text",
        !@active && "text-secondary hover:text-foreground hover:bg-surface-secondary"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  # -- Role assignments summary --
  #
  # Compact rendering of "what does this principal have access to?". Groups
  # assignments by role so the role badge shows once per group and the
  # projects line up after — much cleaner than one `[project: role]` pill per
  # row when many projects share the same role.
  #
  # Used by both the Users page and the Teams page so the visualization stays
  # symmetric across the two views.

  attr :assignments, :list,
    required: true,
    doc:
      "list of `%{project: %Project{}, role_name: \"applier\", sources: [...]}`. " <>
        "`sources` is optional and used as a hover tooltip on each project."

  attr :empty_message, :string, default: "No projects"

  attr :all_label, :string,
    default: nil,
    doc: "if set, display this string instead of the per-role groups (e.g. super-user marker)"

  def role_assignments_summary(assigns) do
    assigns = assign(assigns, :grouped, group_assignments_by_role(assigns.assignments))

    ~H"""
    <div :if={@all_label} class="text-xs text-muted">{@all_label}</div>
    <div :if={is_nil(@all_label) and @assignments == []} class="text-xs text-muted">{@empty_message}</div>
    <div :if={is_nil(@all_label) and @assignments != []} class="space-y-1">
      <div :for={{role_name, items} <- @grouped} class="flex items-start gap-2">
        <div class="shrink-0">
          <.badge color={role_badge_color_for(role_name)}>{String.capitalize(role_name)}</.badge>
        </div>
        <div class="flex flex-wrap gap-x-2 gap-y-0.5 text-xs">
          <a
            :for={a <- items}
            href={"/admin/projects/#{a.project.uuid}"}
            title={a[:sources] && Enum.join(a.sources, ", ")}
            class="text-clickable hover:text-clickable-hover"
          >{a.project.name}</a>
        </div>
      </div>
    </div>
    """
  end

  defp group_assignments_by_role(assignments) do
    assignments
    |> Enum.group_by(& &1.role_name)
    |> Enum.map(fn {role, items} ->
      {role, Enum.sort_by(items, & &1.project.name)}
    end)
    |> Enum.sort_by(fn {role, _} -> -role_rank(role) end)
  end

  # Stable rank for ordering role groups (admin first, custom roles last).
  defp role_rank("admin"), do: 3
  defp role_rank("applier"), do: 2
  defp role_rank("planner"), do: 1
  defp role_rank(_), do: 0

  defp role_badge_color_for("planner"), do: "blue"
  defp role_badge_color_for("applier"), do: "green"
  defp role_badge_color_for("admin"), do: "purple"
  defp role_badge_color_for(_), do: "gray"

  # -- Dark mode toggle --
  #
  # Both 🌙 and ☀️ ship in the rendered HTML; CSS picks the right one via the
  # `.dark` class set by the inline <head> script before paint. The hook only
  # toggles the class and persists the preference — no innerHTML mutation.

  attr :id, :string, default: "dark-mode-toggle"

  def dark_mode_toggle(assigns) do
    ~H"""
    <button id={@id} phx-hook=".DarkMode" class="text-lg cursor-pointer leading-none" title="Toggle dark mode">
      <span class="dark:hidden">{"\u{1F319}"}</span>
      <span class="hidden dark:inline">{"\u{2600}\u{FE0F}"}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DarkMode">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            document.documentElement.classList.toggle("dark")
            let dark = document.documentElement.classList.contains("dark")
            localStorage.setItem("theme", dark ? "dark" : "light")
          })
        }
      }
    </script>
    """
  end

  # -- Copy to clipboard button --
  #
  # Wraps a button that copies the textContent of `data-target` into the
  # clipboard, briefly flashing "Copied!" as feedback. Owns the .CopyButton hook.

  attr :id, :string, required: true
  attr :target, :string, required: true, doc: "CSS selector for the source element"

  attr :class, :string,
    default:
      "px-3 py-1.5 text-xs rounded-lg bg-input text-secondary border border-border-input hover:bg-surface-secondary cursor-pointer"

  slot :inner_block

  def copy_button(assigns) do
    ~H"""
    <button id={@id} phx-hook=".CopyButton" data-target={@target} class={@class}>
      {render_slot(@inner_block) || "Copy"}
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            let target = document.querySelector(this.el.dataset.target)
            if (!target) return
            let text = target.textContent || target.innerText
            navigator.clipboard.writeText(text).then(() => {
              let orig = this.el.textContent
              this.el.textContent = "Copied!"
              setTimeout(() => { this.el.textContent = orig }, 1500)
            })
          })
        }
      }
    </script>
    """
  end

  # -- JSON viewer with syntax highlighting --
  #
  # Pretty-prints + syntax-highlights JSON content using CSS variables so it
  # adapts to the active theme. Owns the .JsonViewer hook.

  attr :id, :string, required: true
  attr :class, :string, default: "text-xs font-mono whitespace-pre-wrap text-state-viewer-text"
  attr :rest, :global
  slot :inner_block, required: true

  def json_viewer(assigns) do
    ~H"""
    <pre id={@id} phx-hook=".JsonViewer" class={@class} {@rest}>{render_slot(@inner_block)}</pre>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".JsonViewer">
      export default {
        mounted() { this.highlight() },
        updated() { this.highlight() },
        highlight() {
          let raw = this.el.textContent
          try {
            let parsed = JSON.parse(raw)
            this.el.innerHTML = this.colorize(JSON.stringify(parsed, null, 2))
          } catch(e) {}
        },
        colorize(json) {
          let s = getComputedStyle(document.documentElement)
          let ck = s.getPropertyValue('--json-key').trim()
          let cs = s.getPropertyValue('--json-string').trim()
          let cn = s.getPropertyValue('--json-number').trim()
          let cb = s.getPropertyValue('--json-boolean').trim()
          let cl = s.getPropertyValue('--json-null').trim()
          return json.replace(/("(?:\\.|[^"\\])*")\s*:/g, `<span style="color:${ck}">$1</span>:`)
            .replace(/:\s*("(?:\\.|[^"\\])*")/g, `: <span style="color:${cs}">$1</span>`)
            .replace(/:\s*(\d+\.?\d*)/g, `: <span style="color:${cn}">$1</span>`)
            .replace(/:\s*(true|false)/g, `: <span style="color:${cb}">$1</span>`)
            .replace(/:\s*(null)/g, `: <span style="color:${cl}">$1</span>`)
        }
      }
    </script>
    """
  end

  # -- Logo --
  #
  # Inlined as a base64 data URI at compile time so the brand mark renders
  # synchronously with the page HTML — no second network roundtrip, no flash
  # on slow connections. Source is the white silhouette (`ico-dark.png`); the
  # `invert dark:invert-0` classes flip it to black on light backgrounds and
  # leave it white on dark backgrounds. The CSS visibility decision still
  # resolves before first paint thanks to the inline `<head>` script that sets
  # the `.dark` class.

  @external_resource Path.expand("../../../priv/static/images/ico-dark.png", __DIR__)
  @logo_data_uri "data:image/png;base64," <>
                   Base.encode64(File.read!(@external_resource))

  attr :class, :string, default: "h-8"

  def logo(assigns) do
    assigns = assign(assigns, :data_uri, @logo_data_uri)

    ~H"""
    <span class="inline-flex">
      <img src={@data_uri} alt="Lynx" class={"#{@class} invert dark:invert-0"} />
    </span>
    """
  end

  # -- Helpers --

  defp select_display_label(%{multiple: true, options: options, value: value}) do
    values = List.wrap(value) |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
    labels = for {label, v} <- options, to_string(v) in values, do: label
    if labels == [], do: "Select...", else: Enum.join(labels, ", ")
  end

  defp select_display_label(%{options: options, value: value, prompt: prompt}) do
    case Enum.find(options, fn {_label, v} -> to_string(v) == to_string(value) end) do
      {label, _} -> label
      nil -> prompt || "Select..."
    end
  end

  defp select_option_active?(opt_value, %{multiple: true, value: value}) do
    to_string(opt_value) in Enum.map(List.wrap(value), &to_string/1)
  end

  defp select_option_active?(opt_value, %{value: value}) do
    to_string(opt_value) == to_string(value)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
