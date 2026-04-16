defmodule LynxWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(LynxWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(LynxWeb.Gettext, "errors", msg, opts)
    end
  end
end
