# BluetabPhoenix

An [Igniter](https://hexdocs.pm/igniter) installer that patches an Ash Phoenix project with Bluetab defaults: Google OAuth login, admin user support, authenticated routing, and branded login UI.

**Source:** https://gitlab.bluetab.net/internalapps/tools/bluetab_phoenix

## Prerequisites

This installer is designed to run on top of a project generated with:

```bash
mix archive.install hex igniter_new --force
mix archive.install hex phx_new 1.8.3 --force

mix igniter.new my_app --with phx.new --install ash,ash_phoenix \
  --install ash_postgres,ash_authentication \
  --install ash_authentication_phoenix,ash_admin \
  --install ash_oban,oban_web --install live_debugger,tidewave \
  --install ash_ai,usage_rules --setup --yes
```

## Installation

```sh
mix igniter.install bluetab_phoenix@github:Bluetab/bluetab_phoenix
```

### Or

Add `bluetab_phoenix` as a dependency in your project's `mix.exs`:

```elixir
def deps do
  [
    {:bluetab_phoenix, git: "https://github.com/Bluetab/bluetab_phoenix.git"}
  ]
end
```

Then run:

```bash
mix deps.get
mix bluetab_phoenix.install
```

The installer will show a diff of all proposed changes and ask for confirmation before applying.

## What it does

The installer applies the following changes to your project:

### Google OAuth

- Adds a `google` strategy to the User resource (`Accounts.User`)
- Adds a `register_with_google` action with attribute mapping from Google user info
- Makes the **first Google sign-up on an empty database** an admin automatically (bootstrap admin)
- Adds user attributes: `email`, `given_name`, `family_name`, `picture`, `is_admin`, `confirmed_at`
- Adds a `unique_email` identity
- Configures `Secrets` module with `secret_for/4` clauses that read `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and `GOOGLE_REDIRECT_URI` from environment variables
- Removes the default `add_ons` block (e.g. `log_out_everywhere`) from the User resource

### Authenticated routing

- Replaces the default `ash_authentication_live_session :authenticated_routes` block with one that mounts `HomeLive` at `/`
- Adds an `ash_authentication_live_session :admin_routes` block that mounts `AdminLive` at `/admin`
- Removes password-specific routes (`reset_route`, `confirm_route`, `magic_sign_in_route`)
- Removes the default `PageController` and its templates (replaced by `HomeLive`)

### Admin support

- Grants admin to the first user who registers via Google when the `users` table is empty
- Adds an `is_admin` boolean attribute (default `false`) to the User resource
- Adds a `live_admin_required` guard to `LiveUserAuth` that checks `is_admin`
- Creates `HomeLive` (authenticated) and `AdminLive` (admin-only) LiveView pages

### AshAdmin

- Relocates the AshAdmin dashboard route from `/admin` to `/admin/ash` inside the `dev_routes` block, so it doesn't conflict with the custom `AdminLive` page

### UI & Branding

- Updates the app layout with `bt-shell--app`, `bt_topbar`, theme toggle, user menu, and sign-out
- Styles `HomeLive` and `AdminLive` with design-system typography (`bt-hero`, `bt-eyebrow`, etc.)
- Configures `AuthOverrides` with Bluetab-branded login banner (light/dark images, app name)
- Copies `bluetab_ibm_light.png` and `bluetab_ibm_dark.png` to `priv/static/images/`
- Adds `.env` to `.gitignore`

### Bluetab Design System (`bds`)

- Adds `{:bds, github: "Bluetab/bds"}` to `mix.exs`
- Imports `deps/bds/priv/static/bds.css` from `assets/css/app.css`
- Calls `initBtInteractions()` from `assets/js/app.js` (esbuild alias to `deps/bds`)
- Loads Titillium Web via Google Fonts and bootstraps `bt-theme` in `root.html.heex`
- Imports `Bds.Components` in the web module for `bt_*` function components

Reference consumer: the `ds_tester` app in the monorepo.

## After installation

1. Fetch dependencies and build assets:

   ```bash
   mix deps.get
   mix assets.build
   ```

2. Generate and run the database migration:

   ```bash
   mix ash_postgres.generate_migrations --name google_login
   mix ash_postgres.migrate
   ```

3. Set the required environment variables (e.g. in a `.env` file):

   ```bash
   GOOGLE_CLIENT_ID=your_client_id
   GOOGLE_CLIENT_SECRET=your_client_secret
   GOOGLE_REDIRECT_URI=http://localhost:4000/auth/user/google/callback
   ```

4. On a fresh database, the **first person to sign in with Google** becomes an admin. To promote others later, set `is_admin: true` on their user record.

## Idempotency

The installer is safe to run multiple times. It checks for existing strategies, secrets, routes, and modules before making changes, so re-running it will not create duplicates.
