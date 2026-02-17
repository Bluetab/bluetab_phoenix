if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BluetabPhoenix.Install do
    @shortdoc "Adds Google OAuth login with admin support to an Ash Authentication Phoenix project"

    @moduledoc """
    Patches a Phoenix project with AshAuthentication to add Google OAuth login,
    admin user support, and authenticated LiveView routing.

    Expects the project to have been created with `mix igniter.new` using
    `--install ash_authentication_phoenix`.

    ## What this installer does

    1. Adds a Google OAuth strategy to the User resource
    2. Adds a `register_with_google` action to the User resource
    3. Adds required attributes (email, given_name, family_name, picture, is_admin, confirmed_at)
    4. Adds a unique email identity
    5. Configures secrets for Google OAuth environment variables
    6. Creates authenticated HomeLive and admin-only AdminLive pages
    7. Adds admin guard (`live_admin_required`) to LiveUserAuth
    8. Configures router with authenticated live sessions and admin routes
    9. Updates the app layout with user info header and admin link
    10. Removes default PageController (replaced by HomeLive)
    11. Removes password-specific routes (reset, confirm, magic link)
    12. Adds `.env` to `.gitignore`

    ## Usage

        mix igniter.install bluetab_phoenix

    ## Environment Variables

    After installation, set these environment variables:

    - `GOOGLE_CLIENT_ID` - Your Google OAuth client ID
    - `GOOGLE_CLIENT_SECRET` - Your Google OAuth client secret
    - `GOOGLE_REDIRECT_URI` - Your OAuth redirect URI
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :bluetab_phoenix,
        example: "mix bluetab_phoenix.install"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      {igniter, user_resource} = find_user_resource(igniter)

      if is_nil(user_resource) do
        Igniter.add_issue(
          igniter,
          """
          Could not find the User resource module (Accounts.User).
          Please ensure your project was created with ash_authentication_phoenix.
          """
        )
      else
        secrets_module = Igniter.Project.Module.module_name(igniter, "Secrets")
        prefix = Igniter.Project.Module.module_name_prefix(igniter)
        web_module = :"#{prefix}Web"
        router_module = Module.concat(web_module, Router)
        layouts_module = Module.concat(web_module, Layouts)
        live_user_auth_module = Module.concat(web_module, LiveUserAuth)
        home_live_module = Module.concat(web_module, HomeLive)
        admin_live_module = Module.concat(web_module, AdminLive)
        app_name = inspect(prefix)

        auth_overrides_module = Module.concat(web_module, AuthOverrides)

        igniter
        # Google OAuth
        |> remove_add_ons(user_resource)
        |> add_google_strategy(user_resource, secrets_module)
        |> add_register_with_google_action(user_resource)
        |> add_user_attributes(user_resource)
        |> add_user_identity(user_resource)
        |> add_google_secrets(secrets_module, user_resource)
        # Auth flow & Admin
        |> add_admin_auth_mount(live_user_auth_module)
        |> create_home_live(home_live_module, web_module, live_user_auth_module, app_name)
        |> create_admin_live(admin_live_module, web_module, live_user_auth_module)
        |> update_router(router_module, live_user_auth_module)
        |> relocate_ash_admin(router_module)
        |> update_layouts_app(layouts_module, app_name)
        |> update_auth_overrides(auth_overrides_module, app_name)
        |> copy_bluetab_images()
        |> remove_page_controller_files(prefix)
        # Common
        |> update_gitignore()
        |> Igniter.add_notice("""
        Google OAuth login with admin support has been configured!

        Next steps:

        1. Generate and run the database migration:

             mix ash_postgres.generate_migrations --name google_login
             mix ash_postgres.migrate

        2. Set the following environment variables (e.g. in a .env file):

             GOOGLE_CLIENT_ID=your_client_id
             GOOGLE_CLIENT_SECRET=your_client_secret
             GOOGLE_REDIRECT_URI=http://localhost:4000/auth/user/google/callback

        3. To make a user an admin, set `is_admin: true` on their record.
        """)
      end
    end

    # ──────────────────────────────────────────────
    # Module Discovery
    # ──────────────────────────────────────────────

    defp find_user_resource(igniter) do
      user_resource = Igniter.Project.Module.module_name(igniter, "Accounts.User")

      case Igniter.Project.Module.module_exists(igniter, user_resource) do
        {true, igniter} -> {igniter, user_resource}
        {false, igniter} -> {igniter, nil}
      end
    end

    # ──────────────────────────────────────────────
    # User Resource: Remove add_ons block
    # ──────────────────────────────────────────────

    defp remove_add_ons(igniter, user_resource) do
      Igniter.Project.Module.find_and_update_module!(igniter, user_resource, fn zipper ->
        with {:ok, auth_zipper} <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(
                 zipper,
                 :authentication,
                 1
               ),
             {:ok, body_zipper} <- Igniter.Code.Common.move_to_do_block(auth_zipper),
             {:ok, add_ons_zipper} <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(
                 body_zipper,
                 :add_ons,
                 1
               ) do
          {:ok, Sourceror.Zipper.remove(add_ons_zipper)}
        else
          _ -> {:ok, zipper}
        end
      end)
    end

    # ──────────────────────────────────────────────
    # User Resource: Add Google strategy
    # ──────────────────────────────────────────────

    defp add_google_strategy(igniter, user_resource, secrets_module) do
      case Igniter.Project.Module.find_module(igniter, user_resource) do
        {:ok, {igniter, source, _}} ->
          content = Rewrite.Source.get(source, :content)

          if Regex.match?(~r/strategies do.*?google do/s, content) do
            igniter
          else
            secrets_str = inspect(secrets_module)

            AshAuthentication.Igniter.add_new_strategy(
              igniter,
              user_resource,
              :google,
              :google,
              """
              google do
                client_id #{secrets_str}
                client_secret #{secrets_str}
                redirect_uri #{secrets_str}
              end
              """
            )
          end

        {:error, igniter} ->
          igniter
      end
    end

    # ──────────────────────────────────────────────
    # User Resource: Add register_with_google action
    # ──────────────────────────────────────────────

    defp add_register_with_google_action(igniter, user_resource) do
      Ash.Resource.Igniter.add_new_action(
        igniter,
        user_resource,
        :register_with_google,
        """
        create :register_with_google do
          argument :user_info, :map, allow_nil?: false
          argument :oauth_tokens, :map, allow_nil?: false
          upsert? true
          upsert_identity :unique_email

          change AshAuthentication.GenerateTokenChange

          # Required if you have the `identity_resource` configuration enabled.
          change AshAuthentication.Strategy.OAuth2.IdentityChange

          change fn changeset, _ ->
            user_info = Ash.Changeset.get_argument(changeset, :user_info)

            Ash.Changeset.change_attributes(
              changeset,
              Map.take(user_info, ["email", "given_name", "family_name", "picture"])
            )
          end

          # Required if you're using the password & confirmation strategies
          upsert_fields []
          change set_attribute(:confirmed_at, &DateTime.utc_now/0)
        end
        """
      )
    end

    # ──────────────────────────────────────────────
    # User Resource: Add attributes
    # ──────────────────────────────────────────────

    defp add_user_attributes(igniter, user_resource) do
      igniter
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :email,
        """
        attribute :email, :string do
          allow_nil? false
        end
        """
      )
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :given_name,
        "attribute :given_name, :string"
      )
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :family_name,
        "attribute :family_name, :string"
      )
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :picture,
        "attribute :picture, :string"
      )
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :is_admin,
        """
        attribute :is_admin, :boolean do
          default false
        end
        """
      )
      |> Ash.Resource.Igniter.add_new_attribute(
        user_resource,
        :confirmed_at,
        """
        attribute :confirmed_at, :datetime do
          allow_nil? false
        end
        """
      )
    end

    # ──────────────────────────────────────────────
    # User Resource: Add identity
    # ──────────────────────────────────────────────

    defp add_user_identity(igniter, user_resource) do
      Ash.Resource.Igniter.add_new_identity(
        igniter,
        user_resource,
        :unique_email,
        "identity :unique_email, [:email]"
      )
    end

    # ──────────────────────────────────────────────
    # Secrets: Add Google OAuth secrets
    # ──────────────────────────────────────────────

    defp add_google_secrets(igniter, secrets_module, user_resource) do
      [
        {[:authentication, :strategies, :google, :client_id], "GOOGLE_CLIENT_ID"},
        {[:authentication, :strategies, :google, :client_secret], "GOOGLE_CLIENT_SECRET"},
        {[:authentication, :strategies, :google, :redirect_uri], "GOOGLE_REDIRECT_URI"}
      ]
      |> Enum.reduce(igniter, fn {path, env_var}, igniter ->
        add_system_env_secret(igniter, secrets_module, user_resource, path, env_var)
      end)
    end

    defp add_system_env_secret(igniter, secrets_module, resource, path, env_var_name) do
      case Igniter.Project.Module.find_module(igniter, secrets_module) do
        {:ok, {igniter, source, _}} ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, env_var_name) do
            igniter
          else
            do_add_system_env_secret(igniter, secrets_module, resource, path, env_var_name)
          end

        {:error, igniter} ->
          do_add_system_env_secret(igniter, secrets_module, resource, path, env_var_name)
      end
    end

    defp do_add_system_env_secret(igniter, secrets_module, resource, path, env_var_name) do
      path_str = inspect(path)
      resource_str = inspect(resource)

      func = """
      def secret_for(
            #{path_str},
            #{resource_str},
            _opts,
            _context
          ) do
        System.fetch_env("#{env_var_name}")
      end
      """

      full = """
      use AshAuthentication.Secret

      #{func}
      """

      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        secrets_module,
        full,
        fn zipper ->
          {:ok, Igniter.Code.Common.add_code(zipper, func)}
        end
      )
    end

    # ──────────────────────────────────────────────
    # LiveUserAuth: Add admin guard
    # ──────────────────────────────────────────────

    defp add_admin_auth_mount(igniter, live_user_auth_module) do
      admin_mount_code = ~S'''
      def on_mount(:live_admin_required, _params, _session, socket) do
        case socket.assigns[:current_user] do
          %{is_admin: true} ->
            {:cont, socket}

          nil ->
            {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}

          _user ->
            socket =
              socket
              |> Phoenix.LiveView.put_flash(:error, "You must be an admin to access this page")
              |> Phoenix.LiveView.redirect(to: ~p"/")

            {:halt, socket}
        end
      end
      '''

      Igniter.Project.Module.find_and_update_module!(igniter, live_user_auth_module, fn zipper ->
        has_admin_mount? =
          Sourceror.Zipper.find(Sourceror.Zipper.topmost(zipper), fn
            :live_admin_required -> true
            _ -> false
          end) != nil

        if has_admin_mount? do
          {:ok, zipper}
        else
          {:ok, Igniter.Code.Common.add_code(zipper, admin_mount_code)}
        end
      end)
    end

    # ──────────────────────────────────────────────
    # LiveViews: Create HomeLive and AdminLive
    # ──────────────────────────────────────────────

    defp create_home_live(igniter, home_live_module, web_module, live_user_auth_module, app_name) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, home_live_module)

      if exists? do
        igniter
      else
        contents = """
        use #{inspect(web_module)}, :live_view

        on_mount {#{inspect(live_user_auth_module)}, :live_user_required}

        @impl true
        def mount(_params, _session, socket) do
          {:ok, socket}
        end

        @impl true
        def render(assigns) do
          ~H\"\"\"
          <Layouts.app flash={@flash} current_user={@current_user}>
            <div class="flex items-center justify-center min-h-[calc(100vh-200px)]">
              <div class="text-center">
                <h1 class="text-4xl font-bold">Welcome to #{app_name}</h1>
                <p class="mt-4 text-lg text-gray-600 dark:text-gray-400">
                  Your authenticated home page
                </p>
              </div>
            </div>
          </Layouts.app>
          \"\"\"
        end
        """

        Igniter.Project.Module.create_module(igniter, home_live_module, contents)
      end
    end

    defp create_admin_live(igniter, admin_live_module, web_module, live_user_auth_module) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, admin_live_module)

      if exists? do
        igniter
      else
        contents = """
        use #{inspect(web_module)}, :live_view

        on_mount {#{inspect(live_user_auth_module)}, :live_admin_required}

        @impl true
        def mount(_params, _session, socket) do
          {:ok, socket}
        end

        @impl true
        def render(assigns) do
          ~H\"\"\"
          <Layouts.app flash={@flash} current_user={@current_user}>
            <div class="flex items-center justify-center min-h-[calc(100vh-200px)]">
              <div class="text-center">
                <h1 class="text-4xl font-bold">Admin Dashboard</h1>
                <p class="mt-4 text-lg text-gray-600 dark:text-gray-400">
                  Admin-only access page
                </p>
              </div>
            </div>
          </Layouts.app>
          \"\"\"
        end
        """

        Igniter.Project.Module.create_module(igniter, admin_live_module, contents)
      end
    end

    # ──────────────────────────────────────────────
    # Router: Full update
    # ──────────────────────────────────────────────

    defp update_router(igniter, router_module, live_user_auth_module) do
      live_user_auth_str = inspect(live_user_auth_module)

      case Igniter.Project.Module.find_and_update_module(igniter, router_module, fn zipper ->
             zipper =
               zipper
               |> replace_authenticated_live_session(live_user_auth_str)
               |> remove_function_call(:reset_route)
               |> remove_function_call(:confirm_route)
               |> remove_function_call(:magic_sign_in_route)
               |> remove_page_controller_route()

             {:ok, zipper}
           end) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_warning(
            igniter,
            "Could not find router module #{inspect(router_module)}. Router modifications skipped."
          )
      end
    end

    defp replace_authenticated_live_session(zipper, live_user_auth_str) do
      case Sourceror.Zipper.find(Sourceror.Zipper.topmost(zipper), fn
             {:ash_authentication_live_session, _, [{:__block__, _, [:authenticated_routes]} | _]} ->
               true

             {:ash_authentication_live_session, _, [:authenticated_routes | _]} ->
               true

             _ ->
               false
           end) do
        nil ->
          Sourceror.Zipper.topmost(zipper)

        found ->
          new_auth_session =
            Sourceror.parse_string!("""
            ash_authentication_live_session :authenticated_routes,
              on_mount: [{#{live_user_auth_str}, :current_user}] do
              live "/", HomeLive
            end
            """)

          replaced =
            found
            |> Sourceror.Zipper.replace(new_auth_session)

          has_admin_routes? =
            Sourceror.Zipper.find(Sourceror.Zipper.topmost(replaced), fn
              {:ash_authentication_live_session, _, [{:__block__, _, [:admin_routes]} | _]} ->
                true

              {:ash_authentication_live_session, _, [:admin_routes | _]} ->
                true

              _ ->
                false
            end) != nil

          if has_admin_routes? do
            Sourceror.Zipper.topmost(replaced)
          else
            new_admin_session =
              Sourceror.parse_string!("""
              ash_authentication_live_session :admin_routes,
                on_mount: [{#{live_user_auth_str}, :current_user}] do
                live "/admin", AdminLive
              end
              """)

            replaced
            |> Sourceror.Zipper.insert_right(new_admin_session)
            |> Sourceror.Zipper.topmost()
          end
      end
    end

    defp remove_page_controller_route(zipper) do
      case Sourceror.Zipper.find(Sourceror.Zipper.topmost(zipper), fn
             {:get, _, args} when is_list(args) ->
               Enum.any?(args, fn
                 {:__aliases__, _, atoms} -> List.last(atoms) == :PageController
                 _ -> false
               end)

             _ ->
               false
           end) do
        nil -> Sourceror.Zipper.topmost(zipper)
        found -> found |> Sourceror.Zipper.remove() |> Sourceror.Zipper.topmost()
      end
    end

    defp remove_function_call(zipper, function_name) do
      zipper
      |> Sourceror.Zipper.topmost()
      |> do_remove_function_call(function_name)
    end

    defp do_remove_function_call(zipper, function_name) do
      case Sourceror.Zipper.find(zipper, fn
             {^function_name, _, _} -> true
             _ -> false
           end) do
        nil ->
          Sourceror.Zipper.topmost(zipper)

        found ->
          found
          |> Sourceror.Zipper.remove()
          |> Sourceror.Zipper.topmost()
          |> do_remove_function_call(function_name)
      end
    end

    # ──────────────────────────────────────────────
    # Router: Relocate AshAdmin to dev_routes
    # (string-based to restructure scope + if block)
    # ──────────────────────────────────────────────

    defp relocate_ash_admin(igniter, router_module) do
      case Igniter.Project.Module.find_module(igniter, router_module) do
        {:ok, {igniter, source, _zipper}} ->
          path = Rewrite.Source.get(source, :path)

          Igniter.update_file(igniter, path, fn source ->
            content = Rewrite.Source.get(source, :content)

            has_ash_admin? =
              String.contains?(content, "ash_admin") or
                String.contains?(content, "AshAdmin.Router")

            already_correct? =
              Regex.match?(~r/:dev_routes.*ash_admin\s+"/s, content) and
                String.contains?(content, ~S'ash_admin "/ash"')

            cond do
              already_correct? ->
                source

              has_ash_admin? ->
                content
                |> remove_standalone_ash_admin()
                |> add_ash_admin_to_dev_routes()
                |> then(&Rewrite.Source.update(source, :content, &1))

              true ->
                source
            end
          end)

        {:error, igniter} ->
          igniter
      end
    end

    defp remove_standalone_ash_admin(content) do
      # First, try to remove a complete `if dev_routes` block dedicated to AshAdmin
      cleaned =
        Regex.replace(
          ~r/\n\s*if Application\.compile_env\([^)]+, :dev_routes\) do\s*\n\s*import AshAdmin\.Router\n.*?ash_admin[^\n]*\n\s*end\n\s*end/s,
          content,
          ""
        )

      if cleaned != content do
        cleaned
      else
        # AshAdmin is mixed with other routes in a shared block;
        # remove just the import, scope, and any standalone ash_admin call
        content
        |> then(&Regex.replace(~r/^\s*import AshAdmin\.Router\s*\n/m, &1, ""))
        |> then(fn c ->
          Regex.replace(
            ~r/\n?\s*scope[^\n]*do\s*\n\s*pipe_through :browser\s*\n\s*\n?\s*ash_admin[^\n]*\n\s*end\s*\n?/,
            c,
            "\n"
          )
        end)
        |> then(&Regex.replace(~r/^\s*ash_admin[^\n]*\n/m, &1, ""))
      end
    end

    defp add_ash_admin_to_dev_routes(content) do
      ash_admin_block =
        String.trim_trailing("""
            import AshAdmin.Router

            scope "/admin" do
              pipe_through :browser

              ash_admin "/ash"
            end
        """)

      cond do
        String.contains?(content, ~S'ash_admin "/ash"') ->
          content

        String.contains?(content, "import Phoenix.LiveDashboard.Router") ->
          String.replace(
            content,
            "    import Phoenix.LiveDashboard.Router",
            ash_admin_block <> "\n\n    import Phoenix.LiveDashboard.Router",
            global: false
          )

        Regex.match?(~r/compile_env.*:dev_routes\) do/, content) ->
          Regex.replace(
            ~r/(compile_env\([^)]+, :dev_routes\) do)\s*\n/,
            content,
            "\\1\n" <> ash_admin_block <> "\n\n",
            global: false
          )

        true ->
          content
      end
    end

    # ──────────────────────────────────────────────
    # Layouts: Update app function (string-based to
    # avoid AST issues with ~H sigil content)
    # ──────────────────────────────────────────────

    defp update_layouts_app(igniter, layouts_module, app_name) do
      new_app_fn = build_app_function(app_name)

      case Igniter.Project.Module.find_module(igniter, layouts_module) do
        {:ok, {igniter, source, _zipper}} ->
          path = Rewrite.Source.get(source, :path)

          Igniter.update_file(igniter, path, fn source ->
            content = Rewrite.Source.get(source, :content)

            content =
              if String.contains?(content, "attr :current_user") do
                content
              else
                String.replace(
                  content,
                  ~S'attr :flash, :map, required: true, doc: "the map of flash messages"',
                  ~S'attr :flash, :map, required: true, doc: "the map of flash messages"' <>
                    "\n" <>
                    ~S'  attr :current_user, :map, default: nil, doc: "the current authenticated user"'
                )
              end

            content =
              Regex.replace(
                ~r/^  def app\(assigns\) do\n.*?^  end/ms,
                content,
                new_app_fn
              )

            Rewrite.Source.update(source, :content, content)
          end)

        {:error, igniter} ->
          Igniter.add_warning(
            igniter,
            "Could not find layouts module #{inspect(layouts_module)}. Layout modifications skipped."
          )
      end
    end

    defp build_app_function(app_name) do
      ~S'''
        def app(assigns) do
          ~H"""
          <header class="bg-base-200 border-b border-base-300">
            <div class="navbar px-4 sm:px-6 lg:px-8 max-w-7xl mx-auto h-12 min-h-12">
              <div class="flex-1">
                <.link navigate={~p"/"} class="text-xl font-bold">
                  APP_NAME_PLACEHOLDER
                </.link>
              </div>
              <div class="flex-none">
                <div class="flex items-center gap-3">
                  <Layouts.theme_toggle />
                  <%= if @current_user do %>
                    <%= if @current_user.is_admin do %>
                      <.link navigate={~p"/admin"} class="btn btn-xs btn-primary">
                        Admin
                      </.link>
                    <% end %>
                    <span class="text-sm">{@current_user.email}</span>
                    <.link href={~p"/sign-out"} class="btn btn-xs btn-ghost">
                      Log out
                    </.link>
                  <% end %>
                </div>
              </div>
            </div>
          </header>

          <main class="px-4 py-8 sm:px-6 lg:px-8">
            <div class="mx-auto max-w-7xl">
              {render_slot(@inner_block)}
            </div>
          </main>

          <.flash_group flash={@flash} />
          """
        end
      '''
      |> String.trim_trailing()
      |> String.replace("APP_NAME_PLACEHOLDER", app_name)
    end

    # ──────────────────────────────────────────────
    # File cleanup: Remove PageController
    # ──────────────────────────────────────────────

    defp remove_page_controller_files(igniter, prefix) do
      app_name = prefix |> Module.split() |> List.last() |> Macro.underscore()
      base = "lib/#{app_name}_web/controllers"

      [
        "#{base}/page_controller.ex",
        "#{base}/page_html.ex",
        "#{base}/page_html/home.html.heex"
      ]
      |> Enum.reduce(igniter, fn path, igniter ->
        if Igniter.exists?(igniter, path) do
          Igniter.rm(igniter, path)
        else
          igniter
        end
      end)
    end

    # ──────────────────────────────────────────────
    # AuthOverrides: Bluetab branded login
    # ──────────────────────────────────────────────

    defp update_auth_overrides(igniter, auth_overrides_module, app_name) do
      override_code = """
      override AshAuthentication.Phoenix.Components.Banner do
        set :root_class, "flex flex-col-reverse items-center justify-center py-10 gap-2"
        set :image_class, "w-20"
        set :image_url, "/images/bluetab_ibm_light.png"
        set :dark_image_url, "/images/bluetab_ibm_dark.png"
        set :text, "#{app_name}"
        set :text_class, "text-4xl font-bold text-center"
        set :href_class, "text-center"
      end
      """

      case Igniter.Project.Module.find_and_update_module(igniter, auth_overrides_module, fn zipper ->
             has_banner? =
               Sourceror.Zipper.find(Sourceror.Zipper.topmost(zipper), fn
                 {:override, _, _} -> true
                 _ -> false
               end) != nil

             if has_banner? do
               {:ok, zipper}
             else
               {:ok, Igniter.Code.Common.add_code(zipper, override_code)}
             end
           end) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_warning(
            igniter,
            "Could not find AuthOverrides module #{inspect(auth_overrides_module)}. Auth styling skipped."
          )
      end
    end

    # ──────────────────────────────────────────────
    # Static assets: Copy Bluetab images
    # ──────────────────────────────────────────────

    defp copy_bluetab_images(igniter) do
      src_dir = Application.app_dir(:bluetab_phoenix, "priv/static/images")
      dst_dir = "priv/static/images"

      for file <- ["bluetab_ibm_light.png", "bluetab_ibm_dark.png"] do
        src = Path.join(src_dir, file)
        dst = Path.join(dst_dir, file)

        unless File.exists?(dst) do
          File.mkdir_p!(dst_dir)
          File.cp!(src, dst)
        end
      end

      igniter
    end

    # ──────────────────────────────────────────────
    # Gitignore: Add .env
    # ──────────────────────────────────────────────

    defp update_gitignore(igniter) do
      Igniter.create_or_update_file(igniter, ".gitignore", ".env\n", fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, ".env") do
          source
        else
          new_content = String.trim_trailing(content) <> "\n.env\n"
          Rewrite.Source.update(source, :content, new_content)
        end
      end)
    end
  end
end
