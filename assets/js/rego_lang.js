// Monaco Monarch tokenizer for OPA Rego.
//
// Rego doesn't ship with Monaco; we register a tiny tokens provider
// here so policy authors get keyword + comment + string highlighting
// in the Lynx UI. Idempotent — multiple editors share one registration.
//
// Reference: https://www.openpolicyagent.org/docs/policy-language/

const REGO_KEYWORDS = [
  "package",
  "import",
  "as",
  "default",
  "else",
  "false",
  "if",
  "in",
  "not",
  "null",
  "some",
  "true",
  "with",
  "every",
  "contains",
];

const REGO_BUILTINS = [
  "allow",
  "deny",
  "violation",
  "input",
  "data",
  "sprintf",
  "concat",
  "count",
  "max",
  "min",
  "sum",
  "trim",
  "upper",
  "lower",
  "regex.match",
  "startswith",
  "endswith",
];

export function registerRego(monaco) {
  if (!monaco) return;

  const existing = monaco.languages.getLanguages().some((l) => l.id === "rego");
  if (existing) return;

  monaco.languages.register({ id: "rego", extensions: [".rego"] });

  monaco.languages.setMonarchTokensProvider("rego", {
    defaultToken: "",
    tokenPostfix: ".rego",
    keywords: REGO_KEYWORDS,
    builtins: REGO_BUILTINS,
    operators: [
      "=", ":=", "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&", "|",
    ],
    symbols: /[=><!~?:&|+\-*\/^%]+/,
    tokenizer: {
      root: [
        // package + import statements highlight specially
        [/\b(package|import)\b/, "keyword"],
        // identifiers + keywords + builtins
        [/[a-zA-Z_][\w\.]*/, {
          cases: {
            "@keywords": "keyword",
            "@builtins": "type.identifier",
            "@default": "identifier",
          },
        }],
        // numbers
        [/\d+\.\d+/, "number.float"],
        [/\d+/, "number"],
        // strings
        [/"([^"\\]|\\.)*$/, "string.invalid"],
        [/"/, { token: "string.quote", bracket: "@open", next: "@string" }],
        // comments
        [/#.*$/, "comment"],
        // delimiters + operators
        [/[{}()\[\]]/, "@brackets"],
        [/@symbols/, "operator"],
        [/[,.;]/, "delimiter"],
        // whitespace
        [/\s+/, "white"],
      ],
      string: [
        [/[^\\"]+/, "string"],
        [/\\./, "string.escape"],
        [/"/, { token: "string.quote", bracket: "@close", next: "@pop" }],
      ],
    },
  });

  monaco.languages.setLanguageConfiguration("rego", {
    comments: { lineComment: "#" },
    brackets: [["{", "}"], ["[", "]"], ["(", ")"]],
    autoClosingPairs: [
      { open: "{", close: "}" },
      { open: "[", close: "]" },
      { open: "(", close: ")" },
      { open: '"', close: '"' },
    ],
  });
}
