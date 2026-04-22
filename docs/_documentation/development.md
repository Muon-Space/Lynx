---
layout: documentation-single
title: Development
description: Local dev setup, codebase architecture, and the test infrastructure.
keywords: terraform-backend, lynx, terraform, development
comments: false
order: 5
hero:
    title: Development
    text: Local dev setup, codebase architecture, and the test infrastructure.
---

## Local setup

Lynx is built with Elixir 1.19+, Erlang/OTP 28+, and PostgreSQL 16+.

```bash
docker run -d --name lynx-pg -p 5432:5432 \
  -e POSTGRES_USER=lynx -e POSTGRES_PASSWORD=lynx -e POSTGRES_DB=lynx_dev \
  postgres:16

git clone git@github.com:Muon-Space/Lynx.git && cd Lynx
make deps && make migrate && make run
```

Open `http://localhost:4000` and complete the install wizard. The dev server has live reloading — changes to LiveView modules, components, and HEEx templates are reflected in the browser automatically.

If your local PostgreSQL uses different credentials, override via env vars: `DB_USERNAME`, `DB_PASSWORD`, `DB_HOSTNAME`, `DB_DATABASE`, `DB_PORT`. Defaults live in `config/dev.exs`.

## Makefile commands

```bash
make deps        # fetch dependencies
make migrate     # create + migrate the database (mix ecto.setup)
make run         # start the dev server on port 4000
make test        # run the test suite (mix test --trace)
make ci          # run mix coveralls (enforces the 70% coverage gate)
make build       # compile with --warnings-as-errors
make fmt         # format code
make fmt_check   # check formatting without modifying
make i           # interactive iex -S mix phx.server
```

## Architecture

```
lib/lynx/
├── model/          # Ecto schemas
├── context/        # Resource-scoped data + business logic (one per resource)
├── service/        # Cross-resource orchestration (auth, OIDC, SCIM, install, settings, ...)
├── middleware/     # Plug pipelines (UI auth, API auth, SCIM auth, request logger)
├── worker/         # Background workers (snapshot generation)
└── application.ex  # Supervision tree

lib/lynx_web/
├── components/     # Function components (`<.button>`, `<.modal>`, `<.role_assignments_summary>`, ...)
├── live/           # LiveViews (one per route)
├── controllers/    # JSON / HTTP controllers (REST API, /tf/, /scim/v2/, /auth/)
├── router.ex       # Pipelines + route table
└── endpoint.ex
```

### Context vs Service

* **`Lynx.Context.X`** owns everything for a single resource — Ecto queries, validations, business orchestration. Single home for "what can I do with a User / Project / Environment / ...".
* **`Lynx.Service.X`** is for cross-resource orchestration that doesn't belong to any single resource. Examples: `Service.OIDCBackend` (validates JWT against multiple contexts), `Service.SCIM` (provisions users + teams together), `Service.Install` (multi-step setup procedure).

Naming convention for collisions inside a Context:

* `get_X_by_uuid/1` returns the raw struct (or `nil`).
* `fetch_X_by_uuid/1` returns `{:ok, X}` or `{:not_found, msg}` — for callers that pattern-match on tagged tuples.
* `create_X/1` takes a record (the result of `new_X/1`) and returns `Repo.insert` result.
* `create_X_from_data/1` takes a user-facing data map, generates the record, formats errors as a string.
* `_for_user` suffix on user-scoped versions of admin queries (e.g. `count_projects_for_user(user_id)` vs `count_projects()`).

### Role / permission layer

`Lynx.Context.RoleContext` is the gatekeeper for every per-project authorization decision.

```elixir
RoleContext.permissions/0                            # canonical list of permission strings
RoleContext.default_roles/0                          # ["planner", "applier", "admin"]
RoleContext.effective_permissions(user, proj)        # MapSet — project-wide grants only
RoleContext.effective_permissions(user, proj, env)   # env-aware: env overrides win, fall back to project-wide
RoleContext.can?(user, project, "state:write")       # boolean shortcut
RoleContext.has?(perm_set, "state:write")            # boolean check on a precomputed MapSet
RoleContext.list_user_project_access(user)           # for the Users page Projects column

# Custom role CRUD (see `/admin/roles`)
RoleContext.create_role(%{name: ..., description: ..., permissions: [...]})
RoleContext.update_role(role, attrs)                 # refuses on system roles
RoleContext.delete_role(role)                        # refuses if in use or system
RoleContext.count_role_usage(role_id)                # for "in use" badge
```

Effective permissions union grants from teams (every team the user belongs to that's attached to the project) and any direct `user_projects` row. Super users always get every permission.

OIDC rule matches return a permission set; `EnvironmentContext.is_access_allowed/1` returns `{:ok, project, env, permissions :: MapSet}` for callers (the TF controller) to gate per-action.

### LiveView + colocated hooks

Phoenix LiveView 1.1+. We use **colocated hooks** — JS for a component lives in a `<script :type={Phoenix.LiveView.ColocatedHook} name=".X">` tag right next to the component definition. Compile-time extraction handles the bundle wiring.

`assets/js/app.js` is intentionally minimal: it imports `phoenix-colocated/lynx` and merges the hooks into the LiveSocket. New hooks should be colocated with their owner component, never added to `app.js`.

### Streams for unbounded lists

`audit_live` and `snapshots_live` use LV 1.0+ `stream/4` instead of `assign(:rows, list)`. Filter changes call `stream(socket, :events, page, reset: true)`; "Load more" appends with no `reset:`. Tracking `:has_more?` and `:next_offset` assigns drives the button visibility. `phx-update="stream"` on the `<tbody>` lets LV emit per-row patches instead of re-rendering the whole list.

### Combobox (`<.combobox>`) for autocomplete dropdowns

`<.combobox>` (in `lib/lynx_web/components/core_components.ex`) replaces eager-loaded `<.input type="select">` for picking users / teams / projects / workspaces. The pattern:

1. Server provides `:options` (current search results, `[{label, value}, ...]`) and `:selected` (`{label, value}` or list for multi).
2. Search input is wrapped in `phx-update="ignore"` so the typed value persists across re-renders. The enclosing `<form phx-change>` reads `_q_<name>` from params and re-runs the search.
3. The colocated `.Combobox` hook owns chip rendering, open/close, and hidden-input mutation. After every server re-render the hook re-applies its `isOpen` state in `updated()` (otherwise morphdom would reset `class="hidden"` on the dropdown).
4. Each context that backs a combobox has a paired `search_<resource>(query, limit \\ 25)` function. LIKE-special chars (`%`, `_`, `\`) are escaped via `Lynx.Search.escape_like/1` so user input can't break the query.

### Theming

All colors are CSS variables in `assets/css/app.css`:

* Use semantic Tailwind classes (`bg-surface`, `text-foreground`, `border-border`, `bg-flash-success-bg`, ...) — not raw `bg-gray-100` etc.
* Both light (`:root`) and dark (`.dark`) variable sets are defined; toggling the `.dark` class on `<html>` flips everything atomically.
* Native `<select>` elements need explicit `text-foreground` since the OS default text color won't follow the theme. Prefer `<.input type="select">` for static option lists, `<.combobox>` for searchable lists from larger collections.

## Testing

The suite uses three case modules:

* **`Lynx.DataCase`** — Repo + DB sandbox. For pure context tests.
* **`LynxWeb.ConnCase`** — Phoenix.ConnTest setup. For controller tests.
* **`LynxWeb.LiveCase`** — adds Phoenix.LiveViewTest. Provides factories (`create_user/1`, `create_super/1`, `create_workspace/1`, `create_project/1`, `create_env/2`, `create_state/2`, `create_lock/2`) and the `log_in_user/2` helper that writes the session keys `LiveAuth` reads.

Common test helpers:

* `mark_installed/0` — seeds the configs `app_key`, `app_name`, etc. that user-creation paths depend on for password hashing.
* `set_config/2` — toggle individual configs.
* `install_admin_and_get_api_key/1` (in ConnCase) — full install flow that returns the admin's API key for `x-api-key` headers.
* `with_api_key/2` — sets the `x-api-key` header.

### Test gotchas

* **Default workspace exists.** Migration `20260421000001_create_workspaces.exs` seeds a `Default` workspace, so a fresh test DB has 1 workspace, not 0.
* **`UserContext.create_user_from_data/1` reads `app_key` for bcrypt salt.** Without `mark_installed/0`, bcrypt raises `ArgumentError: salt must be 29 bytes long`.
* **API auth returns 403 (not 401)** for missing key — controllers use a `regular_user`/`super_user` plug that returns Forbidden.
* **JSON shape:** API uses camelCase + `id` (sourced from `uuid`). `LockJSON` is the one PascalCase exception (Terraform protocol requirement).
* **Custom select / combobox uses `phx-update="ignore"`.** The `form()` test helper validates form values against rendered options, but our select / combobox only renders the current value. Bypass with `render_change(view, "event_name", params)` directly. For combobox autocomplete tests, pass `_q_<name>` in params to drive the search.
* **Renaming `Lynx.Module.X` is gone.** Everything is `Lynx.Context.X` or `Lynx.Service.X` now (PR #22).

### Coverage gate

`make ci` runs `mix coveralls` with a **70% minimum** (set in `coveralls.json`). The HTML report is at `cover/excoveralls.html` after `make coverage_html`.

The gate is intentionally set just below the current coverage so it can only go up. When coverage rises, bump the floor in `coveralls.json` to lock in the gain.

## Contributing

* Run `make ci`, `make build`, and `make fmt_check` before pushing — these all run in CI on every PR.
* Keep PRs focused. Aron prefers reviewable PRs over big-bang refactors.
* Server-side over client-side for permission checks. UI hide is for affordance, not security; always re-check on the handler.
* Don't add comments that explain *what* code does — the names should do that. Comments are for *why* (a constraint, an invariant, a workaround).
