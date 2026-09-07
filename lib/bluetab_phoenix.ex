defmodule BluetabPhoenix do
  @moduledoc """
  Igniter installer support for Bluetab Phoenix apps.

  The install task (`mix bluetab_phoenix.install`) patches consumer projects with
  Google OAuth, Docker/CI defaults, and the Bluetab Design System shell — including
  the top navigation bar used in the Tempo reference app.

  Layout and locale snippets live in `BluetabPhoenix.Layouts` and
  `BluetabPhoenix.Locale` so generated code stays aligned with Tempo.
  """

  alias BluetabPhoenix.Layouts
  alias BluetabPhoenix.Locale

  @doc """
  Returns the `Layouts.app/1` function source for a consumer app.
  """
  def app_layout_function(app_name, web_module),
    do: Layouts.app_function(app_name, web_module)

  @doc """
  Returns helper functions injected into the consumer `Layouts` module.
  """
  def layout_helpers(web_module), do: Layouts.layout_helpers(web_module)

  @doc false
  def locale_plug_source(web_module, otp_app),
    do: Locale.set_locale_plug(web_module, otp_app)

  @doc false
  def locale_controller_source(web_module),
    do: Locale.locale_controller(web_module)

  @doc false
  def live_user_auth_locale_helpers(web_module),
    do: Locale.live_user_auth_locale_helpers(web_module)
end
