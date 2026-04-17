defmodule LynxWeb.CoreComponents do
  @moduledoc """
  Shared UI components for the Lynx admin interface.
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
        "fixed top-4 right-4 z-50 rounded-lg px-4 py-3 shadow-lg text-sm max-w-md",
        @kind == :info && "bg-emerald-50 dark:bg-emerald-900/30 text-emerald-800 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800",
        @kind == :error && "bg-red-50 dark:bg-red-900/30 text-red-800 dark:text-red-300 border border-red-200 dark:border-red-800"
      ]}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide()}
    >
      <div class="flex items-center gap-2">
        <span :if={@kind == :info}>✓</span>
        <span :if={@kind == :error}>✕</span>
        <span>{msg}</span>
      </div>
    </div>
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
          <div class="w-full max-w-2xl rounded-xl bg-white dark:bg-gray-900 p-6 shadow-xl ring-1 ring-gray-200 dark:ring-gray-700 relative pointer-events-auto">
            <button :if={@on_close} phx-click={@on_close} class="absolute top-4 right-4 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 text-xl cursor-pointer">&times;</button>
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
          <div class="w-full max-w-sm rounded-xl bg-white dark:bg-gray-900 p-6 shadow-xl pointer-events-auto">
            <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">{@title}</h3>
            <p class="text-sm text-gray-600 dark:text-gray-400 mb-6">{@message}</p>
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
        <thead class="border-b border-gray-200 dark:border-gray-700 text-left text-gray-500 dark:text-gray-400 font-medium">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            class={["border-b border-gray-100 dark:border-gray-800 hover:bg-gray-50 dark:hover:bg-gray-800", @row_click && "cursor-pointer"]}
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
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} class="px-4 py-8 text-center text-gray-400 dark:text-gray-500">
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
        class="px-3 py-1.5 text-sm rounded border border-gray-300 dark:border-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>
      <span class="text-sm text-gray-500 dark:text-gray-400">{@page} / {@total_pages}</span>
      <button
        phx-click="next_page"
        disabled={@page >= @total_pages}
        class="px-3 py-1.5 text-sm rounded border border-gray-300 dark:border-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:opacity-40 disabled:cursor-not-allowed"
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

  defp badge_color("green"), do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-400"
  defp badge_color("red"), do: "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-400"
  defp badge_color("yellow"), do: "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-400"
  defp badge_color("blue"), do: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-400"
  defp badge_color("purple"), do: "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-400"
  defp badge_color(_), do: "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"

  # -- Button --

  attr :type, :string, default: "button"
  attr :variant, :string, default: "primary"
  attr :size, :string, default: "md"
  attr :class, :string, default: ""
  attr :rest, :global
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
    do: "bg-blue-600 text-white hover:bg-blue-700 focus:ring-blue-500"

  defp button_variant("secondary"),
    do:
      "bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 focus:ring-gray-500"

  defp button_variant("danger"), do: "bg-red-600 text-white hover:bg-red-700 focus:ring-red-500"

  defp button_variant("ghost"),
    do:
      "text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-white hover:bg-gray-100 dark:hover:bg-gray-800 focus:ring-gray-500"

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
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="peer sr-only"
          {@rest}
        />
        <div class="w-10 h-5 bg-gray-200 dark:bg-gray-600 peer-checked:bg-blue-600 rounded-full transition-colors"></div>
        <div class="absolute top-0.5 left-0.5 w-4 h-4 bg-white dark:bg-gray-300 rounded-full shadow peer-checked:translate-x-5 transition-transform"></div>
      </div>
      <span :if={@label} class="text-sm font-medium text-gray-700">{@label}</span>
    </label>
    <p :if={@hint} class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@hint}</p>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign(assigns, :display_label, select_display_label(assigns))

    ~H"""
    <div>
      <label :if={@label} class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">{@label}</label>
      <div
        id={@id || @name}
        phx-hook="CustomSelect"
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
          class="w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 dark:text-gray-100 px-3 py-2 text-sm text-left flex items-center justify-between hover:border-gray-400 focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 cursor-pointer"
        >
          <span data-label class="truncate">{@display_label}</span>
          <svg class="w-4 h-4 text-gray-400 shrink-0 ml-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        <div data-dropdown class="hidden absolute z-50 mt-1 w-full rounded-lg border border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-800 shadow-lg max-h-60 overflow-auto">
          <div :if={@prompt} data-value="" data-label={@prompt} class="px-3 py-2 text-sm text-gray-400 hover:bg-gray-50 cursor-pointer">{@prompt}</div>
          <div
            :for={{label, value} <- @options}
            data-value={value}
            data-label={label}
            data-selected={to_string(select_option_active?(value, assigns))}
            class={["px-3 py-2 text-sm hover:bg-blue-50 dark:hover:bg-blue-900/30 cursor-pointer flex items-center gap-2", select_option_active?(value, assigns) && "bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400"]}
          >
            <span :if={@multiple} data-check class="text-blue-500 w-4">{if select_option_active?(value, assigns), do: "✓", else: ""}</span>
            {label}
          </div>
        </div>
      </div>
      <p :if={@hint} class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class="w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 dark:text-gray-100 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 dark:text-gray-100 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      />
      <p :if={@hint} class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # -- Error --

  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-red-600">{render_slot(@inner_block)}</p>
    """
  end

  # -- Page Header --

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  def page_header(assigns) do
    ~H"""
    <div class="bg-gradient-to-r from-gray-900 to-gray-800 rounded-2xl px-8 py-10 mb-8">
      <h1 class="text-3xl font-bold text-white">{@title}</h1>
      <p :if={@subtitle} class="mt-2 text-gray-400">{@subtitle}</p>
    </div>
    """
  end

  # -- Card --

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["bg-white dark:bg-gray-900 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 p-6", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # -- Nav --

  attr :current_user, :any, required: true
  attr :active, :string, default: ""

  def nav(assigns) do
    ~H"""
    <nav class="bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-700 px-6 py-3 mb-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-8">
          <a href="/" class="flex items-center gap-2">
            <img src="/images/ico.png" alt="Lynx" class="h-8" />
          </a>
          <div :if={@current_user} class="flex items-center gap-1">
            <.nav_link href="/admin/projects" active={@active == "projects"}>Projects</.nav_link>
            <.nav_link href="/admin/snapshots" active={@active == "snapshots"}>Snapshots</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/teams" active={@active == "teams"}>Teams</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/users" active={@active == "users"}>Users</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/settings" active={@active == "settings"}>Settings</.nav_link>
            <.nav_link :if={@current_user.role == "super"} href="/admin/audit" active={@active == "audit"}>Audit Log</.nav_link>
          </div>
        </div>
        <div :if={@current_user} class="flex items-center gap-4">
          <a href="/admin/profile" class="text-sm text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white">{@current_user.name}</a>
          <a href="/logout" class="text-sm text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300">Logout</a>
          <button id="dark-mode-toggle" phx-hook="DarkMode" class="text-lg cursor-pointer leading-none" title="Toggle dark mode"></button>
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
        @active && "bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400",
        !@active && "text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white hover:bg-gray-50 dark:hover:bg-gray-800"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
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
