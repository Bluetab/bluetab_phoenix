defmodule BluetabPhoenix.Locale do
  @moduledoc false

  @doc false
  def set_locale_plug(web_module, otp_app) do
    module = Module.concat(web_module, Plugs.SetLocale)
    gettext = inspect(Module.concat(web_module, Gettext))
    cookie_key = "_#{otp_app}_locale"

    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      Sets Gettext locale from query param, session, or cookie (`#{cookie_key}`).
      Default locale is Spanish (`es`).
      \"\"\"
      import Plug.Conn

      @cookie_key "#{cookie_key}"
      @session_key :locale

      def init(opts), do: opts

      def call(conn, _opts) do
        locale = resolve_locale(conn)
        Gettext.put_locale(#{gettext}, locale)
        Gettext.put_locale(Bds.Gettext, locale)

        conn
        |> assign(:locale, locale)
        |> put_session(@session_key, locale)
        |> put_resp_cookie(@cookie_key, locale, max_age: 60 * 60 * 24 * 365, http_only: false)
      end

      @doc "Persists locale after an explicit user choice (e.g. LiveView toggle)."
      def put_locale(conn, locale) when locale in ["es", "en"] do
        Gettext.put_locale(#{gettext}, locale)
        Gettext.put_locale(Bds.Gettext, locale)

        conn
        |> assign(:locale, locale)
        |> put_session(@session_key, locale)
        |> put_resp_cookie(@cookie_key, locale, max_age: 60 * 60 * 24 * 365, http_only: false)
      end

      def locales, do: Application.get_env(:#{otp_app}, :locales, ~w(es en))

      def default_locale, do: Application.get_env(:#{otp_app}, :default_locale, "es")

      defp resolve_locale(conn) do
        conn.params["locale"] ||
          get_session(conn, @session_key) ||
          conn.cookies[@cookie_key] ||
          default_locale()
          |> to_string()
          |> validate_locale()
      end

      defp validate_locale(locale) do
        if locale in locales(), do: locale, else: default_locale()
      end
    end
    """
    |> String.trim_trailing()
  end

  @doc false
  def locale_controller(web_module) do
    set_locale = inspect(Module.concat(web_module, Plugs.SetLocale))

    """
    defmodule #{inspect(Module.concat(web_module, LocaleController))} do
      use #{inspect(web_module)}, :controller

      def set(conn, %{"locale" => locale}) do
        return = conn.params["return"] || "/"

        conn
        |> #{set_locale}.put_locale(locale)
        |> redirect(to: return)
      end
    end
    """
    |> String.trim_trailing()
  end

  @doc false
  def live_user_auth_locale_helpers(web_module) do
    set_locale = inspect(Module.concat(web_module, Plugs.SetLocale))
    gettext = inspect(Module.concat(web_module, Gettext))

    """
      defp assign_locale(socket, session) do
        locale =
          session["locale"] ||
            session[:locale] ||
            #{set_locale}.default_locale()

        locale =
          if locale in #{set_locale}.locales(),
            do: locale,
            else: #{set_locale}.default_locale()

        Gettext.put_locale(#{gettext}, locale)
        Gettext.put_locale(Bds.Gettext, locale)
        assign(socket, :locale, locale)
      end

      defp attach_locale_hook(socket) do
        Phoenix.LiveView.attach_hook(socket, :set_locale, :handle_event, fn
          "set_locale", %{"locale" => locale}, socket ->
            if locale in #{set_locale}.locales() do
              return = return_path(socket)

              {:halt,
               Phoenix.LiveView.redirect(socket,
                 to: ~p"/set-locale/\#{locale}?\#{%{return: return}}"
               )}
            else
              {:halt, socket}
            end

          _event, _params, socket ->
            {:cont, socket}
        end)
      rescue
        _ -> socket
      end

      defp attach_path_hook(socket) do
        Phoenix.LiveView.attach_hook(
          socket,
          :active_path,
          :handle_params,
          fn _params, url, socket ->
            path =
              case URI.parse(url) do
                %URI{path: nil} -> "/"
                %URI{path: path} -> path
              end

            {:cont, Phoenix.Component.assign(socket, :current_path, path)}
          end
        )
      rescue
        _ -> socket
      end

      defp return_path(socket) do
        case socket.assigns[:current_path] do
          path when is_binary(path) and path != "" -> path
          _ -> "/"
        end
      end
    """
    |> String.trim_trailing()
  end

  @doc false
  def current_user_on_mount_body do
    """
    {:cont,
     socket
     |> AshAuthentication.Phoenix.LiveSession.assign_new_resources(session)
     |> assign_locale(session)
     |> attach_path_hook()
     |> attach_locale_hook()}
    """
    |> String.trim_trailing()
  end

  @doc false
  def live_no_user_on_mount_body do
    """
    {:cont,
     socket
     |> assign(:current_user, nil)
     |> assign_locale(session)
     |> attach_path_hook()
     |> attach_locale_hook()}
    """
    |> String.trim_trailing()
  end
end
