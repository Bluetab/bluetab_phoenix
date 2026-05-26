if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BluetabPhoenix.Install do
    @shortdoc "Adds Google OAuth, Docker release, and CI to an Ash Authentication Phoenix project"

    @moduledoc """
    Patches a Phoenix project with AshAuthentication to add Google OAuth login,
    admin user support, authenticated LiveView routing, Docker release setup,
    GitLab CI pipeline, and production-ready database configuration.

    Expects the project to have been created with `mix igniter.new` using
    `--install ash_authentication_phoenix`.

    ## What this installer does

    ### Google OAuth & Auth
    1. Adds a Google OAuth strategy to the User resource
    2. Adds a `register_with_google` action to the User resource (first sign-up on an empty
       database becomes admin automatically)
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

    ### Docker Release & CI
    13. Generates a Dockerfile for production releases
    14. Generates a `.dockerignore` file
    15. Creates a `Release` module with migrate/rollback functions
    16. Creates release overlay scripts (`rel/overlays/bin/server` and `migrate`)
    17. Removes Windows `.bat` overlay scripts
    18. Adds a `.gitlab-ci.yml` pipeline (publish, deploy_prod)
    19. Adds a `ci/env.sh` helper for ECR login and image tagging
    20. Refactors `runtime.exs` to use individual DB env vars instead of `DATABASE_URL`

    ## Usage

        mix igniter.install bluetab_phoenix

    ## Environment Variables

    After installation, set these environment variables:

    - `GOOGLE_CLIENT_ID` - Your Google OAuth client ID
    - `GOOGLE_CLIENT_SECRET` - Your Google OAuth client secret
    - `GOOGLE_REDIRECT_URI` - Your OAuth redirect URI
    - `DB_USER` - Database username (production)
    - `DB_PASSWORD` - Database password (production)
    - `DB_NAME` - Database name (production)
    - `DB_HOST` - Database hostname (production)
    - `DB_PORT` - Database port (production, defaults to 5432)
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
        repo_module = Module.concat(prefix, Repo)

        igniter
        # Google OAuth
        |> remove_add_ons(user_resource)
        |> add_google_strategy(user_resource, secrets_module)
        |> add_register_with_google_action(user_resource, repo_module)
        |> add_user_attributes(user_resource)
        |> add_user_identity(user_resource)
        |> add_google_secrets(secrets_module, user_resource)
        # Auth flow & Admin
        |> add_admin_auth_mount(live_user_auth_module)
        |> create_home_live(home_live_module, web_module, live_user_auth_module, app_name)
        |> create_admin_live(admin_live_module, web_module, live_user_auth_module)
        |> update_router(router_module, live_user_auth_module)
        |> clean_sign_in_route(router_module)
        |> relocate_ash_admin(router_module)
        |> update_layouts_app(layouts_module, app_name)
        |> update_auth_overrides(auth_overrides_module, app_name)
        |> copy_bluetab_images()
        |> remove_page_controller_files(prefix)
        # Common
        |> update_gitignore()
        |> remove_force_ssl_config()
        # Docker release & CI
        |> generate_release_files(prefix)
        |> create_gitlab_ci(prefix)
        |> create_ci_env_sh()
        |> refactor_runtime_db_config()
        |> Igniter.add_notice("""
        Bluetab Phoenix has been configured with Google OAuth, Docker release, and CI!

        Next steps:

        1. Generate and run the database migration:

             mix ash_postgres.generate_migrations --name google_login
             mix ash_postgres.migrate

        2. Set the following environment variables (e.g. in a .env file):

             GOOGLE_CLIENT_ID=your_client_id
             GOOGLE_CLIENT_SECRET=your_client_secret
             GOOGLE_REDIRECT_URI=http://localhost:4000/auth/user/google/callback

        3. Sign in with Google once on a fresh database — the first user becomes an admin
           automatically. Additional users are non-admin unless you promote them.

        4. Review the generated Dockerfile and .gitlab-ci.yml for your deployment setup.

        5. Set the following database environment variables for production:

             DB_USER=your_db_user
             DB_PASSWORD=your_db_password
             DB_NAME=your_db_name
             DB_HOST=your_db_host
             DB_PORT=5432
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

    defp add_register_with_google_action(igniter, user_resource, repo_module) do
      bootstrap = first_admin_bootstrap_change_snippet(repo_module)

      igniter
      |> Ash.Resource.Igniter.add_new_action(
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
        #{bootstrap}
          # Never overwrite admin or id on OAuth upsert (returning sign-in).
          upsert_fields {:replace_all_except, [:is_admin, :id]}
          change set_attribute(:confirmed_at, &DateTime.utc_now/0)
        end
        """
      )
      |> add_first_admin_bootstrap(user_resource, repo_module)
    end

    # Patches an existing `register_with_google` action (e.g. from a prior installer run).
    defp add_first_admin_bootstrap(igniter, user_resource, repo_module) do
      marker = "force_change_attribute(cs, :is_admin, true)"

      case Igniter.Project.Module.find_module(igniter, user_resource) do
        {:ok, {igniter, source, _}} ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, marker) or
               not String.contains?(content, "register_with_google") do
            igniter
          else
            new_content = patch_register_with_google_first_admin(content, repo_module)

            Igniter.Project.Module.find_and_update_module!(igniter, user_resource, fn _zipper ->
              {:ok, Sourceror.parse_string!(new_content)}
            end)
          end

        {:error, igniter} ->
          igniter
      end
    end

    defp first_admin_bootstrap_change_snippet(repo_module) do
      repo_str = inspect(repo_module)

      """
          change fn changeset, _context ->
            Ash.Changeset.before_action(changeset, fn cs ->
              if #{repo_str}.aggregate("users", :count, :id) == 0 do
                Ash.Changeset.force_change_attribute(cs, :is_admin, true)
              else
                cs
              end
            end)
          end
      """
    end

    defp patch_register_with_google_first_admin(content, repo_module) do
      bootstrap = first_admin_bootstrap_change_snippet(repo_module)

      content =
        Regex.replace(
          ~r/(create :register_with_google do[\s\S]*?)(\n\s+upsert_fields)/,
          content,
          fn _, before, upsert_line ->
            before <> "\n" <> bootstrap <> upsert_line
          end
        )

      Regex.replace(
        ~r/(create :register_with_google do[\s\S]*?)upsert_fields \[\]/,
        content,
        fn _, before ->
          before <> "upsert_fields {:replace_all_except, [:is_admin, :id]}"
        end
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
    # Router: Remove register/reset paths from sign_in_route
    # ──────────────────────────────────────────────

    defp clean_sign_in_route(igniter, router_module) do
      case Igniter.Project.Module.find_module(igniter, router_module) do
        {:ok, {igniter, source, _}} ->
          path = Rewrite.Source.get(source, :path)

          Igniter.update_file(igniter, path, fn source ->
            content = Rewrite.Source.get(source, :content)

            content =
              content
              |> remove_sign_in_kwopt(:register_path)
              |> remove_sign_in_kwopt(:reset_path)

            Rewrite.Source.update(source, :content, content)
          end)

        {:error, igniter} ->
          igniter
      end
    end

    defp remove_sign_in_kwopt(content, key) do
      key_str = Atom.to_string(key)

      content
      # Option on the same line as sign_in_route, with more options on the next line
      |> then(
        &Regex.replace(
          ~r/(sign_in_route[ \t]+)#{key_str}:[ \t]*"[^"]*",[ \t]*\n[ \t]+/,
          &1,
          "\\1"
        )
      )
      # Option on its own continuation line
      |> then(&Regex.replace(~r/^[ \t]*#{key_str}:[ \t]*"[^"]*",?[ \t]*\n/m, &1, ""))
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

      case Igniter.Project.Module.find_and_update_module(
             igniter,
             auth_overrides_module,
             fn zipper ->
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
             end
           ) do
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

    # ──────────────────────────────────────────────
    # Prod config: Remove force_ssl block
    # ──────────────────────────────────────────────

    defp remove_force_ssl_config(igniter) do
      Igniter.update_file(igniter, "config/prod.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, "force_ssl") do
          # Match through the outer `force_ssl` closing `]` (2-space indent in phx_new 1.8),
          # not the inner `exclude:` `]` (4-space indent).
          content =
            Regex.replace(
              ~r/\n?# Force using SSL[\s\S]*?force_ssl: \[[\s\S]*?\n  \]\n/,
              content,
              "\n"
            )

          Rewrite.Source.update(source, :content, content)
        else
          source
        end
      end)
    end

    # ──────────────────────────────────────────────
    # Docker Release: Dockerfile, scripts, module
    # ──────────────────────────────────────────────

    defp generate_release_files(igniter, prefix) do
      otp_app = prefix |> Module.split() |> List.last() |> Macro.underscore()
      release_module = Module.concat(prefix, Release)

      igniter
      |> create_dockerfile(otp_app)
      |> create_dockerignore()
      |> create_release_module(release_module, otp_app)
      |> create_release_scripts(otp_app, release_module)
      |> remove_bat_files()
    end

    defp create_dockerfile(igniter, otp_app) do
      {elixir_vsn, otp_vsn} = detect_versions()

      template = ~S"""
      # Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
      # instead of Alpine to avoid DNS resolution issues in production.
      #
      # https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
      # https://hub.docker.com/_/ubuntu/tags
      #
      # This file is based on these images:
      #
      #   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
      #   - https://hub.docker.com/_/debian/tags?name=bookworm-slim - for the release image
      #   - https://pkgs.org/ - resource for finding needed packages
      #   - Ex: docker.io/hexpm/elixir:<%= elixir_vsn %>-erlang-<%= otp_vsn %>-debian-bookworm-20251117-slim
      #
      ARG ELIXIR_VERSION=<%= elixir_vsn %>
      ARG OTP_VERSION=<%= otp_vsn %>
      ARG DEBIAN_VERSION=bookworm-20251117-slim

      ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
      ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

      FROM ${BUILDER_IMAGE} AS builder

      # install build dependencies
      RUN apt-get update \
        && apt-get install -y --no-install-recommends build-essential git \
        && rm -rf /var/lib/apt/lists/*

      # prepare build dir
      WORKDIR /app

      # install hex + rebar
      RUN mix local.hex --force \
        && mix local.rebar --force

      # set build ENV
      ENV MIX_ENV="prod"

      # install mix dependencies
      COPY mix.exs mix.lock ./
      RUN mix deps.get --only $MIX_ENV
      RUN mkdir config

      # copy compile-time config files before we compile dependencies
      # to ensure any relevant config change will trigger the dependencies
      # to be re-compiled.
      COPY config/config.exs config/${MIX_ENV}.exs config/
      RUN mix deps.compile

      RUN mix assets.setup

      COPY priv priv

      COPY lib lib

      # Compile the release
      RUN mix compile

      COPY assets assets

      # compile assets
      RUN mix assets.deploy

      # Changes to config/runtime.exs don't require recompiling the code
      COPY config/runtime.exs config/

      COPY rel rel
      RUN mix release

      # start a new build stage so that the final image will only contain
      # the compiled release and other runtime necessities
      FROM ${RUNNER_IMAGE} AS final

      RUN apt-get update \
        && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates \
        && rm -rf /var/lib/apt/lists/*

      # Set the locale
      RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
        && locale-gen

      ENV LANG=en_US.UTF-8
      ENV LANGUAGE=en_US:en
      ENV LC_ALL=en_US.UTF-8

      WORKDIR "/app"
      RUN chown nobody /app

      # set runner ENV
      ENV MIX_ENV="prod"

      # Only copy the final release from the build stage
      COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/<%= otp_app %> ./

      USER nobody

      # If using an environment that doesn't automatically reap zombie processes, it is
      # advised to add an init process such as tini via `apt-get install`
      # above and adding an entrypoint. See https://github.com/krallin/tini for details
      # ENTRYPOINT ["/tini", "--"]

      CMD ["/app/bin/server"]
      """

      content =
        EEx.eval_string(template, elixir_vsn: elixir_vsn, otp_vsn: otp_vsn, otp_app: otp_app)

      Igniter.create_new_file(igniter, "Dockerfile", content, on_exists: :skip)
    end

    defp create_dockerignore(igniter) do
      content = ~S"""
      # This file excludes paths from the Docker build context.
      #
      # By default, Docker's build context includes all files (and folders) in the
      # current directory. Even if a file isn't copied into the container it is still sent to
      # the Docker daemon.
      #
      # There are multiple reasons to exclude files from the build context:
      #
      # 1. Prevent nested folders from being copied into the container (ex: exclude
      #    /assets/node_modules when copying /assets)
      # 2. Reduce the size of the build context and improve build time (ex. /build, /deps, /doc)
      # 3. Avoid sending files containing sensitive information
      #
      # More information on using .dockerignore is available here:
      # https://docs.docker.com/engine/reference/builder/#dockerignore-file

      .dockerignore

      # Ignore git, but keep git HEAD and refs to access current commit hash if needed:
      #
      # $ cat .git/HEAD | awk '{print ".git/"$2}' | xargs cat
      # d0b8727759e1e0e7aa3d41707d12376e373d5ecc
      .git
      !.git/HEAD
      !.git/refs

      # Common development/test artifacts
      /cover/
      /doc/
      /test/
      /tmp/
      .elixir_ls

      # Mix artifacts
      /_build/
      /deps/
      *.ez

      # Generated on crash by the VM
      erl_crash.dump

      # Static artifacts - These should be fetched and built inside the Docker image
      # https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Release.html#module-docker
      /assets/node_modules/
      /priv/static/assets/
      /priv/static/cache_manifest.json
      """

      Igniter.create_new_file(igniter, ".dockerignore", content, on_exists: :skip)
    end

    defp create_release_module(igniter, release_module, otp_app) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, release_module)

      if exists? do
        igniter
      else
        contents = """
        @moduledoc \"\"\"
        Used for executing DB release tasks when run in production without Mix installed.
        \"\"\"
        @app :#{otp_app}

        def migrate do
          load_app()

          for repo <- repos() do
            {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
          end
        end

        def rollback(repo, version) do
          load_app()
          {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
        end

        defp repos do
          Application.fetch_env!(@app, :ecto_repos)
        end

        defp load_app do
          Application.ensure_all_started(:ssl)
          Application.ensure_loaded(@app)
        end
        """

        Igniter.Project.Module.create_module(igniter, release_module, contents)
      end
    end

    defp create_release_scripts(igniter, otp_app, release_module) do
      server_content = """
      #!/bin/sh
      set -eu

      cd -P -- "$(dirname -- "$0")"
      PHX_SERVER=true exec ./#{otp_app} start
      """

      migrate_content = """
      #!/bin/sh
      set -eu

      cd -P -- "$(dirname -- "$0")"
      exec ./#{otp_app} eval #{inspect(release_module)}.migrate
      """

      igniter
      |> Igniter.create_new_file("rel/overlays/bin/server", server_content, on_exists: :skip)
      |> Igniter.create_new_file("rel/overlays/bin/migrate", migrate_content, on_exists: :skip)
    end

    defp remove_bat_files(igniter) do
      ["rel/overlays/bin/server.bat", "rel/overlays/bin/migrate.bat"]
      |> Enum.reduce(igniter, fn path, igniter ->
        if Igniter.exists?(igniter, path), do: Igniter.rm(igniter, path), else: igniter
      end)
    end

    defp detect_versions do
      elixir_vsn = System.version()
      otp_release = :erlang.system_info(:otp_release) |> List.to_string()
      root_dir = :code.root_dir() |> List.to_string()

      otp_vsn =
        case File.read(Path.join([root_dir, "releases", otp_release, "OTP_VERSION"])) do
          {:ok, content} -> String.trim(content)
          _ -> otp_release
        end

      {elixir_vsn, otp_vsn}
    end

    # ──────────────────────────────────────────────
    # CI: GitLab CI and env script
    # ──────────────────────────────────────────────

    defp create_gitlab_ci(igniter, prefix) do
      otp_app = prefix |> Module.split() |> List.last() |> Macro.underscore()

      content = """
      variables:
        APP_NAME: "#{otp_app}"
        VERSION: 0.0.0

      stages:
        - publish
        - deploy

      before_script:
        - source ci/env.sh ecr-login

      publish:
        stage: publish
        tags:
          - docker
        script:
          - docker build -t "${IMAGE}" .
          - docker push "${IMAGE}"

      deploy_prod:
        stage: deploy
        tags:
          - kubectl
        script:
          - aws eks update-kubeconfig --region eu-west-1 --name bia-eks
          - kubectl set image deployment.v1.apps/#{otp_app} #{otp_app}=${IMAGE} --record
          - kubectl rollout status deployment/#{otp_app}
        only:
          - tags
      """

      Igniter.create_new_file(igniter, ".gitlab-ci.yml", content, on_exists: :skip)
    end

    defp create_ci_env_sh(igniter) do
      content = ~S"""

      subcommand=$1
      case "$subcommand" in
        ecr-login)
          LOGIN_SCRIPT=$(docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION mesosphere/aws-cli ecr get-login --no-include-email --region ${AWS_DEFAULT_REGION})
          eval ${LOGIN_SCRIPT}
          export ECR=$(echo $LOGIN_SCRIPT | cut -d/ -f3)
          ;;
      esac

      export VERSION=${CI_COMMIT_TAG:-${VERSION}-alpha.${CI_PIPELINE_IID}}
      export IMAGE="${ECR}/bia/${APP_NAME}:${VERSION}"

      echo "VERSION=$VERSION"
      """

      Igniter.create_new_file(igniter, "ci/env.sh", content, on_exists: :skip)
    end

    # ──────────────────────────────────────────────
    # Runtime config: Replace DATABASE_URL
    # ──────────────────────────────────────────────

    defp refactor_runtime_db_config(igniter) do
      Igniter.update_file(igniter, "config/runtime.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, "DATABASE_URL") do
          content =
            content
            |> remove_database_url_variable()
            |> replace_repo_url_config()

          Rewrite.Source.update(source, :content, content)
        else
          source
        end
      end)
    end

    defp remove_database_url_variable(content) do
      Regex.replace(
        ~r/\s*database_url\s*=\s*\n\s*System\.get_env\("DATABASE_URL"\).*?""".*?"""\s*\n/s,
        content,
        "\n"
      )
    end

    defp replace_repo_url_config(content) do
      replacement =
        Enum.join(
          [
            ~S'    username: System.fetch_env!("DB_USER"),',
            ~S'    password: System.fetch_env!("DB_PASSWORD"),',
            ~S'    database: System.fetch_env!("DB_NAME"),',
            ~S'    hostname: System.fetch_env!("DB_HOST"),',
            ~S'    port: System.get_env("DB_PORT", "5432") |> String.to_integer(),'
          ],
          "\n"
        ) <> "\n"

      String.replace(content, "    url: database_url,\n", replacement, global: false)
    end
  end
end
