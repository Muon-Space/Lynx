---
layout: documentation-single
title: Development
description: How to set up a local development environment and run tests.
keywords: terraform-backend, lynx, terraform, development
comments: false
order: 5
hero:
    title: Development
    text: How to set up a local development environment and run tests.
---

## Development

Lynx is built with Elixir and the Phoenix framework. You need Elixir 1.19+, Erlang/OTP 28+, and PostgreSQL to run it locally.

You can install Elixir using the instructions at [elixir-lang.org/install](https://elixir-lang.org/install.html), which typically installs Erlang as well.

For PostgreSQL, you can run it in Docker:

```bash
docker run -d \
    -e POSTGRES_USER=lynx \
    -e POSTGRES_PASSWORD=lynx \
    -e POSTGRES_DB=lynx_dev \
    -p 5432:5432 \
    --name lynx-pg \
    postgres:16
```

Then clone the repository and set up your environment:

```bash
git clone git@github.com:Muon-Space/Lynx.git
cd Lynx
cp .env.example .env.local   # edit if your database credentials differ
export $(cat .env.local | xargs)
```

The Makefile has all the common commands:

```bash
make deps       # fetch dependencies
make migrate    # create and migrate the database
make run        # start the dev server on port 4000
make test       # run the test suite
make build      # compile with warnings-as-errors
make fmt        # format code
make fmt_check  # check formatting without modifying
```

The dev server supports live reloading — changes to LiveView modules, components, and templates are reflected in the browser automatically.
