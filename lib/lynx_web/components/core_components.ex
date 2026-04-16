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
        @kind == :info && "bg-emerald-50 text-emerald-800 border border-emerald-200",
        @kind == :error && "bg-red-50 text-red-800 border border-red-200"
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
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      class="relative z-50 hidden"
    >
      <div class="fixed inset-0 bg-black/50 transition-opacity" aria-hidden="true" />
      <div class="fixed inset-0 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <div
            class="w-full max-w-2xl rounded-xl bg-white p-6 shadow-xl ring-1 ring-gray-200"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            data-cancel={JS.exec("phx-remove", to: "##{@id}") |> @on_cancel}
          >
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

  # -- Table --

  attr :id, :string, default: nil
  attr :rows, :list, required: true
  attr :empty_message, :string, default: "No records found."
  slot :col, required: true do
    attr :label, :string
  end
  slot :action

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="border-b border-gray-200 text-left text-gray-500 font-medium">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-b border-gray-100 hover:bg-gray-50">
            <td :for={col <- @col} class="px-4 py-3">
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-4 py-3">
              <div class="flex gap-2">
                {render_slot(@action, row)}
              </div>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} class="px-4 py-8 text-center text-gray-400">
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
        class="px-3 py-1.5 text-sm rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>
      <span class="text-sm text-gray-500">{@page} / {@total_pages}</span>
      <button
        phx-click="next_page"
        disabled={@page >= @total_pages}
        class="px-3 py-1.5 text-sm rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed"
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

  defp badge_color("green"), do: "bg-emerald-100 text-emerald-700"
  defp badge_color("red"), do: "bg-red-100 text-red-700"
  defp badge_color("yellow"), do: "bg-amber-100 text-amber-700"
  defp badge_color("blue"), do: "bg-blue-100 text-blue-700"
  defp badge_color("purple"), do: "bg-purple-100 text-purple-700"
  defp badge_color(_), do: "bg-gray-100 text-gray-600"

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
        "inline-flex items-center justify-center rounded-lg font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2",
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

  defp button_variant("primary"), do: "bg-blue-600 text-white hover:bg-blue-700 focus:ring-blue-500"
  defp button_variant("secondary"), do: "bg-white text-gray-700 border border-gray-300 hover:bg-gray-50 focus:ring-gray-500"
  defp button_variant("danger"), do: "bg-red-600 text-white hover:bg-red-700 focus:ring-red-500"
  defp button_variant("ghost"), do: "text-gray-600 hover:text-gray-800 hover:bg-gray-100 focus:ring-gray-500"

  # -- Simple Form --

  attr :for, :any, required: true
  attr :as, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete name rel action enctype method novalidate target multipart)
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
  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
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
    assigns = assign_new(assigns, :checked, fn -> Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value]) end)

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
        <div class="w-10 h-5 bg-gray-200 peer-checked:bg-blue-600 rounded-full transition-colors"></div>
        <div class="absolute top-0.5 left-0.5 w-4 h-4 bg-white rounded-full shadow peer-checked:translate-x-5 transition-transform"></div>
      </div>
      <span :if={@label} class="text-sm font-medium text-gray-700">{@label}</span>
    </label>
    <p :if={@hint} class="mt-1 text-xs text-gray-500">{@hint}</p>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-700 mb-1">{@label}</label>
      <select
        id={@id}
        name={@name}
        class="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="mt-1 text-xs text-gray-500">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-700 mb-1">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="mt-1 text-xs text-gray-500">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-700 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      />
      <p :if={@hint} class="mt-1 text-xs text-gray-500">{@hint}</p>
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
    <div class={["bg-white rounded-xl shadow-sm border border-gray-200 p-6", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # -- Nav --

  attr :current_user, :any, required: true
  attr :active, :string, default: ""

  def nav(assigns) do
    ~H"""
    <nav class="bg-white border-b border-gray-200 px-6 py-3 mb-6">
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
          <a href="/admin/profile" class="text-sm text-gray-600 hover:text-gray-900">{@current_user.name}</a>
          <a href="/logout" class="text-sm text-gray-400 hover:text-gray-600">Logout</a>
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
        @active && "bg-blue-50 text-blue-700",
        !@active && "text-gray-600 hover:text-gray-900 hover:bg-gray-50"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  # -- Helpers --

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
