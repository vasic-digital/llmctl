## Overview

`tests/test_docs_no_literal_keys.sh` is the documentation audit rule "no literal access key in `docs/` or
`templates/`" (idea 1-I09, FR-035). It flags `Authorization: Bearer <literal>`, `--api-key|--openai-api-key|
--key|-k <literal>`, `...API_KEY=<literal>` assignments (environment references `$VAR`, `${VAR}`, `<placeholder>`
and short values under 16 characters are allowed, as are the documented dummies `sk-no-key-required`,
`no-key...`, `not-needed...`) and a bare 43-character mixed-case base64url token (the shape of a generated key).

**12 passing** assertions.

## Prerequisites

`python3`.

## Usage examples

```sh
bash tests/test_docs_no_literal_keys.sh
```

## Edge cases

* **Control needle:** before scanning the tree the test runs the scanner over planted keys of every shape
  (all must be flagged) and over allowed forms (none may be) - a scanner that cannot see a planted key says
  nothing about the tree. It also plants a key into a temp tree and expects exit 1.
* A first draft flagged 15 lines in existing documents, all short placeholders (`--api-key K`,
  `TYPESAFE_API_KEY=local`) or test output text; the 16-character floor and the dummy list resolved them
  without editing any existing document.

## Internal behaviour

The scanner is Python embedded in the test (`scan.py` written to a temp dir) and walks text-like files
(`.md .json .sh .py .js .ts .txt .yaml .toml`).
