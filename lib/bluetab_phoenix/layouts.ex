defmodule BluetabPhoenix.Layouts do
  @moduledoc false

  @doc """
  Returns the `Layouts.app/1` function source installed into consumer apps.

  Matches the Tempo reference app: BDS topbar, locale toggles inside the user
  menu, and theme/locale controls for signed-out sessions.
  """
  def app_function(app_name, web_module) do
    web = inspect(web_module)
    gettext = inspect(Module.concat(web_module, Gettext))

    """
      def app(assigns) do
        assigns =
          assign_new(assigns, :locale, fn ->
            Gettext.get_locale(#{gettext}) ||
              Gettext.get_locale(Bds.Gettext) ||
              #{web}.Plugs.SetLocale.default_locale()
          end)

        ~H\"\"\"
        <div class="bt-shell bt-shell--app">
          <.bt_topbar>
            <:brand>
              <.bt_navbar_logo_link
                navigate={~p"/"}
                logo_src={~p"/images/logo-bluetab.svg"}
                logo_alt="Bluetab"
              >
                #{app_name}
              </.bt_navbar_logo_link>
            </:brand>
            <:actions>
              <%= if @current_user do %>
                <%= if @current_user.is_admin do %>
                  <.link navigate={~p"/admin"} class="bt-nav-link">
                    {gettext("Admin")}
                  </.link>
                <% end %>
                <.bt_navbar_user_menu
                  name={@current_user.given_name || @current_user.email}
                  role={if @current_user.is_admin, do: gettext("Admin"), else: gettext("Member")}
                  initials={user_initials(@current_user)}
                  avatar_src={@current_user.picture}
                >
                  <.bt_navbar_user_menu_prefs>
                    <.bt_navbar_user_menu_locale_toggle
                      locale={current_locale(@locale)}
                      locales={navbar_locales()}
                    />
                    <.bt_navbar_user_menu_theme_toggle />
                  </.bt_navbar_user_menu_prefs>
                  <div class="bt-navbar-menu-divider" />
                  <.link href={~p"/sign-out"} class="bt-navbar-menu-item bt-navbar-menu-item--danger">
                    {gettext("Log out")}
                  </.link>
                </.bt_navbar_user_menu>
              <% else %>
                <.bt_navbar_locale_toggle
                  locale={current_locale(@locale)}
                  locales={navbar_locales()}
                  label={gettext("Toggle language")}
                />
                <.bt_navbar_theme_toggle label={gettext("Toggle theme")} />
              <% end %>
            </:actions>
          </.bt_topbar>

          <main class="bt-main">
            {render_slot(@inner_block)}
          </main>

          <.flash_group id="flash-group" flash={@flash} />
        </div>
        \"\"\"
      end
    """
    |> String.trim_trailing()
  end

  @doc false
  def locale_attr, do: ~s'  attr :locale, :string, default: nil'

  @doc false
  def user_initials_helpers do
    ~S'''
      defp user_initials(%{given_name: given} = user) when is_binary(given) and given != "" do
        [given, Map.get(user, :family_name)]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&String.first/1)
        |> Enum.join()
        |> String.upcase()
      end

      defp user_initials(%{email: email}) when is_binary(email) do
        email |> String.slice(0, 2) |> String.upcase()
      end

      defp user_initials(_), do: "?"
    '''
    |> String.trim_trailing()
  end

  @doc false
  def locale_helpers(web_module) do
    gettext = inspect(Module.concat(web_module, Gettext))
    set_locale = inspect(Module.concat(web_module, Plugs.SetLocale))

    """
      defp current_locale(nil),
        do: Gettext.get_locale(#{gettext}) || #{set_locale}.default_locale()

      defp current_locale(locale), do: locale

      defp navbar_locales do
        [
          %{code: "es", label: gettext("Spanish")},
          %{code: "en", label: gettext("English")}
        ]
      end
    """
    |> String.trim_trailing()
  end

  @doc false
  def layout_helpers(web_module) do
    user_initials_helpers() <> "\n\n" <> locale_helpers(web_module)
  end
end
