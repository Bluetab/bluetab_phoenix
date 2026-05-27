# Fake Login flow (`/dev/fake_login`)

The functionality is implemented as a two-step flow using a LiveView for the UI and a Controller for session creation:

- `live "/fake_login", SpendWeb.Dev.FakeLoginLive` renders the form (GET `/dev/fake_login`)
- `post "/fake_login", SpendWeb.Dev.FakeLoginController, :login` processes the submission (POST `/dev/fake_login`)

Because these routes are inside:

```elixir
if Application.compile_env(:spend, :dev_routes) do
  scope "/dev" do
    ...
  end
end
```

they only exist when `dev_routes` is enabled (`config/dev.exs` sets `dev_routes: true`), so this never reaches production.

## Files involved

| File | Role |
|---|---|
| `lib/spend_web/router.ex` | Routes inside the `dev_routes` guard |
| `lib/spend_web/live/dev/fake_login_live.ex` | LiveView — email form + validation |
| `lib/spend_web/controllers/dev/fake_login_controller.ex` | Controller — user lookup, token generation, session creation |
| `lib/spend/accounts.ex` | Domain — `get_user_by_email` code interface |

## How it works end-to-end

1. User opens `GET /dev/fake_login`.
2. `SpendWeb.Dev.FakeLoginLive` mounts and builds a simple form (`id="fake-login-form"`) with one field: `email`.
3. While typing, `phx-change="validate"` keeps the form state in sync on the server.
4. On submit, `handle_event("save", ...)` checks the email is non-empty and sets `@trigger_submit` to `true`.
5. With `phx-trigger-action={@trigger_submit}` and `action={~p"/dev/fake_login"}`, the browser performs a standard HTTP POST to the controller.
6. `SpendWeb.Dev.FakeLoginController.login/2` receives `%{"fake_login" => %{"email" => email}}`.
7. The controller calls `Spend.Accounts.get_user_by_email(email, authorize?: false)`:
   - **User exists:** generates a JWT, stores it in the session, and redirects to `/`.
   - **User not found:** sets a flash error and redirects back to `/dev/fake_login`.

## How the Ash-based session is created (controller detail)

This project uses **AshAuthentication** with token-based sessions (`require_token_presence_for_authentication?: true`), so a plain subject string in the session is not enough — a valid JWT must be present. The controller handles this in three steps:

```elixir
# 1. Look up the user by email, bypassing policies
{:ok, user} = Spend.Accounts.get_user_by_email(email, authorize?: false)

# 2. Generate a signed JWT for the user
{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

# 3. Attach the token to the user struct's metadata so store_in_session can find it
user = Ash.Resource.put_metadata(user, :token, token)

# 4. Store the user (with token) in the Plug session
conn = AshAuthentication.Plug.Helpers.store_in_session(conn, user)
```

After this, the `:load_from_session` plug in the browser pipeline will recognise the token on subsequent requests, load the user, and assign `current_user` — exactly the same as a real Google OAuth sign-in.

## Why `authorize?: false`

The User resource's policies only have a bypass for `AshAuthenticationInteraction`. Since the fake login lookup is not an authentication interaction, it would be forbidden by default. Passing `authorize?: false` skips policy checks, which is acceptable because this code only runs in dev.

## Why there are both a LiveView and a Controller

- **LiveView** provides a reactive form with validation and the familiar HEEx UI.
- **Controller** handles the actual HTTP POST to create the session, since Plug session manipulation (`put_session`, `configure_session`) must happen in a traditional Plug/Controller flow, not inside a LiveView process.

The LiveView's `phx-trigger-action` attribute bridges the two: when the form is valid the browser submits a real POST to the controller endpoint.
