# Lynx Documentation Site

Source for the public docs at [docs.lynx.muonspace.com]() (or wherever the GitHub Pages CNAME points). Built with Jekyll.

## Layout

```
docs/
├── _config.yml            # Jekyll config
├── _documentation/        # The actual content — one .md per page
│   ├── Installation.md
│   ├── getting-started.md
│   ├── usage.md
│   ├── api-and-tf-provider.md
│   ├── architecture.md
│   └── development.md
├── index.md               # Landing page (homepage features grid)
├── documentation.md       # `/documentation/` index — auto-collects pages above
├── 404.md
├── assets/
└── CNAME
```

Each page in `_documentation/` has YAML front-matter with `order:` to control nav position. Update front-matter when adding a new page or reordering.

## Run locally

```bash
# Install bundler if it doesn't exist
gem install bundler

# Install the required gems
bundle install

# Start the local Jekyll server (defaults to http://localhost:4000)
bundle exec jekyll serve
```

## Editing notes

* **Don't break front-matter.** The `layout`, `title`, `description`, `keywords`, `comments`, and `order` keys are read by the theme. `hero:` controls the page header.
* **Internal links** use the Liquid template helper `{{ site.baseurl }}/documentation/<slug>/`.
* **Code blocks** use triple-backtick fences with a language hint (`hcl`, `bash`, `yaml`, `elixir`, `text`) for syntax highlighting.
* **Callouts** use GitHub-style `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]` blockquotes.

## Publishing

Pushes to `main` trigger the GitHub Pages workflow. The `CNAME` file pins the public domain.
